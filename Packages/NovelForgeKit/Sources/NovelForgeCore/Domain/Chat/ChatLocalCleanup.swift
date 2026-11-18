import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// What this device keeps beside the vault about a chat: its turns, their frames and stop marks (`LocalTurnStore`), the exchanges a next turn replays
/// (`ChatContextExchangeLog`), the turns' records (`ChatTurnRecords`) and their last requests (`ChatCallInspector`). None of it syncs, so a deletion clears
/// it on the deleting device and leaves another device's own rows to that device.
enum ChatLocalCleanup {
  static func forget(session: UUID, in database: Database) throws(StoreError) {
    try forgetTurns(where: "session = ?", [session], in: database)
    try forgetSessionRows(session, in: database)
  }

  /// Every session the novel's derived chats or this device's turns name, a deleted one included.
  static func forget(novel: UUID, in database: Database) throws(StoreError) {
    let sessions = try execute(in: database) { () throws -> Set<UUID> in
      var sessions = Set(try UUID.fetchAll(database, sql: "SELECT session FROM \(ChatSessionState.databaseTableName) WHERE novel = ?", arguments: [novel]))
      if try database.tableExists(LocalTurnStore.turnTable) {
        sessions.formUnion(try UUID.fetchAll(database, sql: "SELECT session FROM \(LocalTurnStore.turnTable) WHERE novel = ?", arguments: [novel]))
      }
      return sessions
    }
    try forgetTurns(where: "novel = ?", [novel], in: database)
    for session in sessions.sorted(by: { $0.uuidString < $1.uuidString }) { try forgetSessionRows(session, in: database) }
  }

  /// The replayed exchanges, the turn records and the Inspector's requests of one session.
  private static func forgetSessionRows(_ session: UUID, in database: Database) throws(StoreError) {
    try ChatContextExchangeLog.forget(session: session, in: database)
    try ChatTurnRecords.forget(session: session, in: database)
    try ChatCallInspector.forget(session: session, in: database)
  }

  /// Clears what this device kept of every chat that now reads as deleted, as when the deletion was made on another device and arrived by sync; returns those
  /// sessions. Read from the session records themselves, so a fault on the chats' derived state cannot hide a deletion. Called at launch before resuming turns.
  @discardableResult
  static func forgetRemovedSessions(in database: Database) throws(StoreError) -> [UUID] {
    let kept = try execute(in: database) { () throws -> Set<UUID> in
      var sessions = Set<UUID>()
      if try database.tableExists(LocalTurnStore.turnTable) {
        sessions.formUnion(try UUID.fetchAll(database, sql: "SELECT DISTINCT session FROM \(LocalTurnStore.turnTable)"))
      }
      if try database.tableExists(ChatContextExchangeLog.table) {
        sessions.formUnion(try UUID.fetchAll(database, sql: "SELECT DISTINCT session FROM \(ChatContextExchangeLog.table)"))
      }
      return sessions
    }
    let records = ReadTransaction(database: database, registry: NovelForgeSchema.registry)
    var removed = [UUID]()
    for session in kept.sorted(by: { $0.uuidString < $1.uuidString }) where try isRemoved(session, in: records) {
      try forget(session: session, in: database)
      removed.append(session)
    }
    return removed
  }

  /// A record this version cannot read counts as deleted when its own `removed` flag says so.
  private static func isRemoved(_ session: UUID, in transaction: ReadTransaction) throws(StoreError) -> Bool {
    let ref = ChatSessionRecord.ref(session)
    let state = try transaction.state(of: ref, scope: .vault)
    switch ChatSessionRecord.reading(state, of: ref) {
    case .absent: return false
    case .readable(let entry): return entry.isRemoved
    case .unreadable:
      guard case .record(let record)? = state else { return false }
      return record[field: CommonField.removed.rawValue]?.value == .bool(true)
    }
  }

  private static func forgetTurns(where condition: String, _ arguments: StatementArguments, in database: Database) throws(StoreError) {
    try execute(in: database) {
      guard try database.tableExists(LocalTurnStore.turnTable) else { return }
      let turns = "SELECT id FROM \(LocalTurnStore.turnTable) WHERE \(condition)"
      for table in [LocalTurnStore.frameTable, LocalTurnStore.stopTable] where try database.tableExists(table) {
        try database.execute(sql: "DELETE FROM \(table) WHERE turn IN (\(turns))", arguments: arguments)
      }
      try database.execute(sql: "DELETE FROM \(LocalTurnStore.turnTable) WHERE \(condition)", arguments: arguments)
    }
  }

  private static func execute<T>(in database: Database, _ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }
}
