import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The naming a turn that opens its session owes it (chat.service.ts:331), as that turn would ask for it.
struct ChatSessionNaming: Equatable, Sendable {
  let session: UUID
  let novel: UUID
  let opening: UUID
  let costTier: CostTier
  let contentMode: ContentMode
}

extension ChatSessionNaming {
  init(_ basis: ChatTurnBasis) {
    self.init(session: basis.session, novel: basis.novel, opening: basis.userMessage, costTier: basis.costTier, contentMode: basis.contentMode)
  }
}

/// `nf_local_chat_naming`, a table of this device's own beside the vault: a naming owed from the transaction that saves the opening message until the naming
/// ends, however it ends, so one that a crash cut off, even after the reply was appended, runs again at the next launch and none runs twice.
enum LocalSessionNamings {
  static let table = "nf_local_chat_naming"
  private static let definition = """
    CREATE TABLE IF NOT EXISTS nf_local_chat_naming (
      session BLOB NOT NULL PRIMARY KEY, novel BLOB NOT NULL, opening BLOB NOT NULL, replica TEXT NOT NULL, cost_tier TEXT NOT NULL, content_mode TEXT NOT NULL
    ) STRICT, WITHOUT ROWID
    """

  static func owe(_ naming: ChatSessionNaming, replica: ReplicaID, in database: Database) throws(StoreError) {
    try execute {
      try database.execute(sql: definition)
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(table) (session, novel, opening, replica, cost_tier, content_mode) VALUES (?, ?, ?, ?, ?, ?)",
        arguments: [naming.session, naming.novel, naming.opening, replica.description, naming.costTier.rawValue, naming.contentMode.rawValue])
    }
  }

  static func isOwed(_ naming: ChatSessionNaming, in database: Database) throws(StoreError) -> Bool {
    try execute {
      guard try database.tableExists(table) else { return false }
      let sql = "SELECT EXISTS (SELECT 1 FROM \(table) WHERE session = ? AND opening = ?)"
      return try Bool.fetchOne(database, sql: sql, arguments: [naming.session, naming.opening]) ?? false
    }
  }

  /// The namings `replica` owes, in session id order; a row this version cannot read is stepped over. A restored or cloned database's rows are not this
  /// device's to run.
  static func owed(replica: ReplicaID, in database: Database) throws(StoreError) -> [ChatSessionNaming] {
    try execute {
      guard try database.tableExists(table) else { return [] }
      let rows = try Row.fetchAll(
        database, sql: "SELECT session, novel, opening, cost_tier, content_mode FROM \(table) WHERE replica = ? ORDER BY session", arguments: [replica.description])
      return rows.compactMap { row in
        guard let session = try? row.decode(UUID.self, forColumn: "session"), let novel = try? row.decode(UUID.self, forColumn: "novel"),
          let opening = try? row.decode(UUID.self, forColumn: "opening"),
          let costTier = (try? row.decode(String.self, forColumn: "cost_tier")).flatMap(CostTier.init(rawValue:)),
          let contentMode = (try? row.decode(String.self, forColumn: "content_mode")).flatMap(ContentMode.init(rawValue:))
        else { return nil }
        return ChatSessionNaming(session: session, novel: novel, opening: opening, costTier: costTier, contentMode: contentMode)
      }
    }
  }

  static func forget(_ naming: ChatSessionNaming, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE session = ? AND opening = ?", arguments: [naming.session, naming.opening])
    }
  }

  static func forget(session: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE session = ?", arguments: [session])
    }
  }

  static func forget(novel: UUID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(table) else { return }
      try database.execute(sql: "DELETE FROM \(table) WHERE novel = ?", arguments: [novel])
    }
  }

  static func sessions(in database: Database) throws(StoreError) -> [UUID] {
    try execute {
      guard try database.tableExists(table) else { return [] }
      return try UUID.fetchAll(database, sql: "SELECT session FROM \(table)")
    }
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
