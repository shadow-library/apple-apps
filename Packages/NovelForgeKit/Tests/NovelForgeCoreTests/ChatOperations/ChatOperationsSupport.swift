import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport

@testable import NovelForgeCore

enum ChatOperationsWorld {
  static let novel = ChatWorld.novel
  static let otherNovel = ChatWorld.otherNovel

  /// A store holding both novels, the first in `mode`.
  static func store(mode: ContentMode = .standard) async throws -> VaultStore {
    let (_, store) = try ChatWorld.store()
    try await Projection.write(store) { transaction in
      try Library.create(NewNovel(title: "The Heir", contentMode: mode), id: novel, in: &transaction)
      try Library.create(NewNovel(title: "Another"), id: otherNovel, in: &transaction)
    }
    return store
  }

  static func session(_ id: UUID, in store: VaultStore) async throws -> RecordReading<ChatSessionRecord> {
    try await store.read { transaction in try ChatSessionRecord.read(id: id, in: transaction) }
  }

  static func record(_ id: UUID, in store: VaultStore) async throws -> ChatSessionRecord? {
    guard case .readable(let entry) = try await session(id, in: store) else { return nil }
    return entry.record
  }

  static func isRemoved(_ id: UUID, in store: VaultStore) async throws -> Bool {
    guard case .readable(let entry) = try await session(id, in: store) else { return false }
    return entry.isRemoved
  }

  static func changeCount(in store: VaultStore) async throws -> Int {
    try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM change_log") ?? 0 }
  }

  static func localRows(_ table: String, session: UUID, in store: VaultStore) async throws -> Int {
    try await store.read { transaction in
      guard try transaction.database.tableExists(table) else { return 0 }
      let column = table == LocalTurnStore.frameTable ? "turn IN (SELECT id FROM \(LocalTurnStore.turnTable) WHERE session = ?)" : "session = ?"
      return try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column)", arguments: [session]) ?? 0
    }
  }

  /// A local turn with one frame and a replayed exchange for the session, as a turn on this device leaves them.
  static func leaveLocalState(session: UUID, novel: UUID = novel, in store: VaultStore) async throws {
    let replica = store.replica
    _ = try await store.write { transaction in
      let turn = UUID()
      try LocalTurnStore.begin(turn, novel: novel, session: session, userMessage: UUID(), replica: replica, at: Date(), in: transaction.database)
      _ = try LocalTurnStore.append([TurnFrame(sequence: 1, event: .delta, data: "{}")], turn: turn, at: Date(), in: transaction.database)
      try transaction.database.execute(
        sql: """
          CREATE TABLE IF NOT EXISTS \(ChatContextExchangeLog.table) (
            session BLOB NOT NULL, reply BLOB NOT NULL, exchange BLOB NOT NULL, PRIMARY KEY (session, reply)
          ) STRICT, WITHOUT ROWID
          """)
      try transaction.database.execute(sql: "INSERT INTO \(ChatContextExchangeLog.table) (session, reply, exchange) VALUES (?, ?, x'7b7d')", arguments: [session, UUID()])
    }
  }

  /// A card editing the premise, staged against the premise as it stands now.
  static func premiseCard(_ id: UUID = UUID(), session: UUID? = ChatWorld.session, in store: VaultStore) async throws -> ProposalRecord {
    let ops = try csOps(#"[{"op": "premise.update", "premise": "a cultivator returns from death"}]"#)
    return try await Projection.write(store) { transaction in
      let baseline = ArtifactStates(try ArtifactStateLoader.states(refs: ["premise"], novel: novel, in: transaction))
      let card = try ProposalCard(novel: novel, session: session, kind: .known(.chat), summary: "Sharpen the premise", changeSet: ops, baseline: baseline)
      let proposal = ProposalRecord(id: id, card: card)
      _ = try proposal.create(in: &transaction)
      return proposal
    }
  }

  static func editBrief(_ brief: String, in store: VaultStore) async throws {
    var changes = NovelChanges()
    changes.brief = .set(brief)
    let edit = changes
    try await Projection.write(store) { transaction in try Library.edit(novel: novel, edit, in: &transaction) }
  }

  static func unrestrictedReply(session: UUID = ChatWorld.session, novel: UUID = novel, in store: VaultStore) async throws {
    try await ChatWorld.append(try ChatWorld.message(novel: novel, session: session, role: .assistant, content: "The heir lives.", mode: .unrestricted), in: store)
  }

  static func fault(_ table: String, _ key: String = ProjectionFaults.wholeDerivation, in store: VaultStore) async throws {
    _ = try await store.write { transaction in
      try transaction.database.execute(sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')", arguments: [table, key])
    }
  }
}
