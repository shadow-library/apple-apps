import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

enum ProposalFixture {
  static let novel = SchemaFixture.novel
  static let session = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000b1")
  static let message = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000b2")

  static let changeSet = """
    [
      {"op": "premise.update", "premise": "a cultivator returns from death", "themes": ["revenge"]},
      {"op": "volume.upsert", "volumeKey": "vol_1", "objective": "survive the sect trials"},
      {"op": "fact.upsert", "factKey": "heir", "body": "The heir lives", "unlock": {"all": [{"milestone": "rank-two"}, {"chapter": 4}]}},
      {"op": "action.approve_draft", "chapter": 1, "revision": 2}
    ]
    """

  static func state(_ hash: String) -> ArtifactState {
    ArtifactState(exists: true, revision: nil, contentHash: hash)
  }

  static func states(_ pairs: [(String, ArtifactState)]) -> ArtifactStates {
    ArtifactStates(Dictionary(pairs.map { (JSString($0.0), $0.1) }) { first, _ in first })
  }

  static let baseline = states([("premise", state("p0")), ("volume:vol_1", .missing), ("fact:heir", state("f0"))])

  static func card(_ text: String = changeSet, novel: UUID = novel, kind: ProposalKind = .chat) throws -> ProposalCard {
    try ProposalCard(
      novel: novel, session: session, message: message, kind: .known(kind), summary: "Sharpen the premise", changeSet: try csOps(text), baseline: baseline,
      warnings: ["“no heir” reads as a removal"], diagnostics: [ProposalDiagnostic(kind: .known(.other), message: "“no heir” reads as a removal")], run: "run-1")
  }

  static func proposal(_ id: UUID = UUID(), card: ProposalCard? = nil) throws -> ProposalRecord {
    ProposalRecord(id: id, card: try card ?? Self.card())
  }

  static func postState(_ hash: String) -> ArtifactStates {
    states([("premise", state(hash))])
  }

  static func sources(automatic: Bool) -> [StoredEnum<OpSource>]? {
    automatic ? [.known(.quoted), .known(.idea), .known(.quoted), .known(.idea)] : nil
  }

  static func application(selected: [Int], _ hash: String, automatic: Bool = false) -> ProposalApplication {
    ProposalApplication(selected: selected, postState: postState(hash), sources: sources(automatic: automatic), automatic: automatic)
  }

  static func undo(_ value: String) throws -> ProposalChangeUndo {
    let inverse = try #require(try csParse(#"{"op": "premise.update", "premise": "\#(value)"}"#).objectValue)
    return try ProposalChangeUndo(inverse: inverse, priorState: states([("premise", state("p0"))]), postState: states([("premise", state(value))]))
  }

  static func change(of proposal: ProposalRecord, _ index: Int, status: ProposalChangeStatus = .applied, undo: ProposalChangeUndo? = nil, result: ProposalChangeResult? = nil)
    throws -> ProposalChangeRecord
  {
    try ProposalChangeRecord(novel: proposal.novel, proposal: proposal.id, index: index, status: status, undo: undo, result: result)
  }

  static func read(_ proposal: ProposalRecord, in store: VaultStore) async throws -> RecordReading<ProposalRecord> {
    try await Harness.read(proposal.ref, as: ProposalRecord.self, in: store)
  }

  static func readChange(_ change: ProposalChangeRecord, in store: VaultStore) async throws -> RecordReading<ProposalChangeRecord> {
    try await Harness.read(change.ref, as: ProposalChangeRecord.self, in: store)
  }

  static func changes(of proposal: ProposalRecord, in store: VaultStore) async throws -> [ProposalChangeEntry] {
    let ref = proposal.ref
    return try await store.read { transaction in
      guard case .readable(let entry) = try ProposalRecord.read(ref, in: transaction) else { return [] }
      return try ProposalChangeRecord.changes(of: entry.record, in: transaction)
    }
  }

  static func apply(
    _ proposal: ProposalRecord, selected: [Int], _ hash: String = "p1", automatic: Bool = false, undo: String, in store: VaultStore
  ) async throws -> ApplyRecording {
    let changes = try selected.map { index in try appliedChange(of: proposal, index, undo: undo) }
    let ref = proposal.ref
    let postState = postState(hash)
    let sources = sources(automatic: automatic)
    return try await store.write { transaction in
      try ProposalRecord.recordApply(ref, changes: changes, postState: postState, sources: sources, automatic: automatic, in: &transaction)
    }
  }

  static func applied(_ proposal: ProposalRecord, _ index: Int, undo: String) throws -> ProposalChangeEntry {
    .recorded(try appliedChange(of: proposal, index, undo: undo))
  }

  // Index 3 of the fixture card is an action: it is recorded pending and has no undo.
  private static func appliedChange(of proposal: ProposalRecord, _ index: Int, undo: String) throws -> ProposalChangeRecord {
    guard index != 3 else { return try change(of: proposal, index, status: .pending) }
    return try change(of: proposal, index, undo: try Self.undo("\(undo)-\(index)"))
  }
}
