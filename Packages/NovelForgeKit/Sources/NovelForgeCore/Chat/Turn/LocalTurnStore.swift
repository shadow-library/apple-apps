import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The turns this device runs, and their frames, in tables of the app's own beside the vault, written through the write transaction's database: nothing in them
/// syncs, a reset of the derived tables leaves them alone, and each write is one SQLite transaction, so a crash leaves a write whole or absent. `begin` belongs
/// in the transaction that appends the author's message and `finish` in the one that appends the reply, so neither message outlives its turn row.
enum LocalTurnStore {
  static let turnTable = "nf_local_turn"
  static let frameTable = "nf_local_turn_frame"
  static let stopTable = "nf_local_turn_stop"
  private static let definitions = [
    """
    CREATE TABLE IF NOT EXISTS nf_local_turn (
      id BLOB NOT NULL PRIMARY KEY, novel BLOB NOT NULL, session BLOB NOT NULL, user_message BLOB NOT NULL, replica TEXT NOT NULL, state TEXT NOT NULL,
      started_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, ended_at INTEGER, error_code TEXT, error_message TEXT, checkpoint BLOB
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS nf_local_turn_session ON nf_local_turn (session, started_at)",
    """
    CREATE TABLE IF NOT EXISTS nf_local_turn_frame (
      turn BLOB NOT NULL, seq INTEGER NOT NULL, event TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (turn, seq)
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE TABLE IF NOT EXISTS nf_local_turn_stop (turn BLOB NOT NULL PRIMARY KEY, stopped_at INTEGER NOT NULL) STRICT, WITHOUT ROWID",
  ]

  /// What a turn this replica stopped running without ending is failed with: the native stand-in for the reference's pending cutoff (chat.service.ts:138, :207).
  static let interrupted = TurnFailure(code: "CHT_013", message: "The turn stopped responding — the app closed while it ran")

  /// A new turn supersedes the session's ended turns, since the reference reports a failure only while the transcript ends on its message
  /// (chat.service.ts:248-251), and the session's turns of another replica, which a restored or cloned database brought along and which never run here.
  static func begin(
    _ id: UUID, novel: UUID, session: UUID, userMessage: UUID, replica: ReplicaID, at now: Date, in database: Database
  ) throws(StoreError) {
    try storeExecute(in: database) {
      try createTables(in: database)
      let superseded = "SELECT id FROM \(turnTable) WHERE session = ? AND (state <> ? OR replica <> ?)"
      let arguments: StatementArguments = [session, LocalTurnState.pending.rawValue, replica.description]
      try database.execute(sql: "DELETE FROM \(frameTable) WHERE turn IN (\(superseded))", arguments: arguments)
      try database.execute(sql: "DELETE FROM \(stopTable) WHERE turn IN (\(superseded)) OR turn = ?", arguments: arguments + [id])
      try database.execute(sql: "DELETE FROM \(turnTable) WHERE id IN (\(superseded))", arguments: arguments)
      try database.execute(
        sql: """
          INSERT INTO \(turnTable) (id, novel, session, user_message, replica, state, started_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [id, novel, session, userMessage, replica.description, LocalTurnState.pending.rawValue, milliseconds(now), milliseconds(now)])
    }
  }

  /// Frames for a turn that is no longer stored or no longer pending are dropped; a frame already stored under its sequence is kept, so a batch written twice
  /// stays one.
  @discardableResult
  static func append(_ frames: [TurnFrame], turn: UUID, at now: Date, in database: Database) throws(StoreError) -> Bool {
    try storeExecute(in: database) {
      guard !frames.isEmpty, try isPending(turn, in: database) else { return false }
      for frame in frames {
        try database.execute(
          sql: "INSERT OR IGNORE INTO \(frameTable) (turn, seq, event, data) VALUES (?, ?, ?, ?)", arguments: [turn, frame.sequence, frame.event.rawValue, frame.data])
      }
      try database.execute(sql: "UPDATE \(turnTable) SET updated_at = ? WHERE id = ?", arguments: [milliseconds(now), turn])
      return true
    }
  }

  /// Replaces the saved round while the turn is pending; a resumed turn that repeats a round saves it again.
  @discardableResult
  static func save(_ checkpoint: LocalTurnCheckpoint, turn: UUID, at now: Date, in database: Database) throws(StoreError) -> Bool {
    try storeExecute(in: database) {
      guard checkpoint.round >= 1, try database.tableExists(turnTable) else { return false }
      try database.execute(
        sql: "UPDATE \(turnTable) SET checkpoint = ?, updated_at = ? WHERE id = ? AND state = ?",
        arguments: [CanonicalJSON.encode(checkpoint.json), milliseconds(now), turn, LocalTurnState.pending.rawValue])
      return database.changesCount > 0
    }
  }

  /// Ends a pending turn; one already ended keeps its first end.
  @discardableResult
  static func end(_ turn: UUID, as end: LocalTurnEnd, at now: Date, in database: Database) throws(StoreError) -> Bool {
    let (state, failure): (LocalTurnState, TurnFailure?) =
      switch end {
      case .failed(let failure): (.failed, failure)
      case .cancelled: (.cancelled, nil)
      }
    return try storeExecute(in: database) {
      guard try database.tableExists(turnTable) else { return false }
      try database.execute(
        sql: "UPDATE \(turnTable) SET state = ?, ended_at = ?, updated_at = ?, error_code = ?, error_message = ? WHERE id = ? AND state = ?",
        arguments: [state.rawValue, milliseconds(now), milliseconds(now), failure?.code, failure?.message, turn, LocalTurnState.pending.rawValue])
      let ended = database.changesCount > 0
      try forgetStop(turn, in: database)
      return ended
    }
  }

  /// The author's Stop, written as soon as it is asked for, so a turn whose process ends before it records its end is ended cancelled at the next launch
  /// instead of resumed; false when the turn is no longer pending.
  @discardableResult
  static func markStopped(_ turn: UUID, at now: Date, in database: Database) throws(StoreError) -> Bool {
    try storeExecute(in: database) {
      guard try isPending(turn, in: database) else { return false }
      try createTables(in: database)
      try database.execute(sql: "INSERT OR IGNORE INTO \(stopTable) (turn, stopped_at) VALUES (?, ?)", arguments: [turn, milliseconds(now)])
      return true
    }
  }

  /// Removes the turn and its frames: in the reply's transaction when it finishes, or when the author dismisses or abandons it.
  static func finish(_ turn: UUID, in database: Database) throws(StoreError) {
    try storeExecute(in: database) {
      guard try database.tableExists(turnTable) else { return }
      try database.execute(sql: "DELETE FROM \(frameTable) WHERE turn = ?", arguments: [turn])
      try forgetStop(turn, in: database)
      try database.execute(sql: "DELETE FROM \(turnTable) WHERE id = ?", arguments: [turn])
    }
  }

  static func turn(_ id: UUID, in database: Database) throws(StoreError) -> LocalTurn? {
    try storeExecute(in: database) {
      guard try database.tableExists(turnTable) else { return nil }
      return try Row.fetchOne(database, sql: "SELECT \(columns(in: database)) FROM \(turnTable) WHERE id = ?", arguments: [id]).flatMap(LocalTurn.init(row:))
    }
  }

  /// Ends as failed every pending turn of `replica` outside `resumed`, returning their ids: after a restart, the interrupted turns the caller does not resume.
  @discardableResult
  static func failStale(replica: ReplicaID, except resumed: Set<UUID>, at now: Date, in database: Database) throws(StoreError) -> [UUID] {
    var failed: [UUID] = []
    for turn in try pending(replica: replica, in: database) where !resumed.contains(turn.id) {
      if try end(turn.id, as: .failed(interrupted), at: now, in: database) { failed.append(turn.id) }
    }
    return failed
  }

  /// The pending turns `replica` began, oldest first: after a restart, the turns that were interrupted. A pending turn of another replica, which a restored or
  /// cloned database brought along, is never resumed here.
  static func pending(replica: ReplicaID, in database: Database) throws(StoreError) -> [LocalTurn] {
    try storeExecute(in: database) {
      guard try database.tableExists(turnTable) else { return [] }
      return try Row.fetchAll(
        database, sql: "SELECT \(columns(in: database)) FROM \(turnTable) WHERE state = ? AND replica = ? ORDER BY started_at, id",
        arguments: [LocalTurnState.pending.rawValue, replica.description]
      ).compactMap(LocalTurn.init(row:))
    }
  }

  /// `lastMessage` is the newest message of the session's transcript (chat.service.ts:223-251): an ended turn shows only while it is that turn's message,
  /// and only when no turn is pending. Only `replica`'s turns count, so another device's turn reads as none here. Rows that cannot be read are stepped over.
  static func status(session: UUID, lastMessage: UUID?, replica: ReplicaID, in database: Database) throws(StoreError) -> LocalTurnStatus {
    try storeExecute(in: database) {
      guard try database.tableExists(turnTable) else { return .idle }
      let turns = try Row.fetchAll(
        database, sql: "SELECT \(columns(in: database)) FROM \(turnTable) WHERE session = ? AND replica = ? ORDER BY started_at DESC, id DESC",
        arguments: [session, replica.description]
      ).compactMap(LocalTurn.init(row:))
      if let pending = turns.first(where: { $0.state == .pending }) { return LocalTurnStatus(pending: pending, ended: nil) }
      guard let ended = turns.first, ended.userMessage == lastMessage else { return .idle }
      return LocalTurnStatus(pending: nil, ended: ended)
    }
  }

  /// The turn's frames after `sequence`, in order; a frame naming no known event is stepped over.
  static func frames(of turn: UUID, after sequence: Int, in database: Database) throws(StoreError) -> [TurnFrame] {
    try storeExecute(in: database) {
      guard try database.tableExists(frameTable) else { return [] }
      return try Row.fetchAll(
        database, sql: "SELECT seq, event, data FROM \(frameTable) WHERE turn = ? AND seq > ? ORDER BY seq", arguments: [turn, sequence]
      ).compactMap { row in
        guard let sequence = try? row.decode(Int.self, forColumn: "seq"), let name = try? row.decode(String.self, forColumn: "event"),
          let event = TurnStreamEventName(rawValue: name), let data = try? row.decode(String.self, forColumn: "data")
        else { return nil }
        return TurnFrame(sequence: sequence, event: event, data: data)
      }
    }
  }

  private static func createTables(in database: Database) throws {
    for definition in definitions { try database.execute(sql: definition) }
  }

  /// A table made before Stop was recorded has no stop table until the next turn begins, and a read cannot create it.
  private static func columns(in database: Database) throws -> String {
    let stopped = try database.tableExists(stopTable) ? "EXISTS (SELECT 1 FROM \(stopTable) WHERE turn = nf_local_turn.id)" : "0"
    return """
      id, novel, session, user_message, replica, state, started_at, updated_at, ended_at, error_code, error_message, checkpoint,
      (SELECT MAX(seq) FROM nf_local_turn_frame WHERE turn = nf_local_turn.id) AS last_seq, \(stopped) AS stopped
      """
  }

  private static func forgetStop(_ turn: UUID, in database: Database) throws {
    guard try database.tableExists(stopTable) else { return }
    try database.execute(sql: "DELETE FROM \(stopTable) WHERE turn = ?", arguments: [turn])
  }

  private static func isPending(_ turn: UUID, in database: Database) throws -> Bool {
    guard try database.tableExists(turnTable) else { return false }
    let sql = "SELECT EXISTS (SELECT 1 FROM \(turnTable) WHERE id = ? AND state = ?)"
    return try Bool.fetchOne(database, sql: sql, arguments: [turn, LocalTurnState.pending.rawValue]) ?? false
  }

  private static func storeExecute<T>(in database: Database, _ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch {
      throw StoreError(projecting: error)
    }
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0
  }
}

extension LocalTurn {
  fileprivate init?(row: Row) {
    guard let id = try? row.decode(UUID.self, forColumn: "id"), let novel = try? row.decode(UUID.self, forColumn: "novel"),
      let session = try? row.decode(UUID.self, forColumn: "session"), let userMessage = try? row.decode(UUID.self, forColumn: "user_message"),
      let replica = (try? row.decode(String.self, forColumn: "replica")).flatMap(ReplicaID.init),
      let state = (try? row.decode(String.self, forColumn: "state")).flatMap(LocalTurnState.init(rawValue:)),
      let startedAt = try? row.decode(Int64.self, forColumn: "started_at"), let updatedAt = try? row.decode(Int64.self, forColumn: "updated_at")
    else { return nil }
    let endedAt = try? row.decode(Int64?.self, forColumn: "ended_at")
    let code = try? row.decode(String?.self, forColumn: "error_code")
    let message = try? row.decode(String?.self, forColumn: "error_message")
    let checkpoint = (try? row.decode(Data?.self, forColumn: "checkpoint")).flatMap { $0 }.flatMap { try? CanonicalJSON.decode($0) }.flatMap(LocalTurnCheckpoint.init(json:))
    self.init(
      id: id, novel: novel, session: session, userMessage: userMessage, replica: replica, state: state, startedAt: Self.date(startedAt),
      updatedAt: Self.date(updatedAt), endedAt: endedAt.flatMap { $0 }.map(Self.date),
      failure: state == .failed ? Self.failure(code: code.flatMap { $0 }, message: message.flatMap { $0 }) : nil,
      lastSequence: (try? row.decode(Int?.self, forColumn: "last_seq")).flatMap { $0 } ?? 0, checkpoint: state == .pending ? checkpoint : nil,
      stopped: state == .pending && (try? row.decode(Bool.self, forColumn: "stopped")) == true)
  }

  private static func failure(code: String?, message: String?) -> TurnFailure? {
    guard let code, let message else { return nil }
    return TurnFailure(code: code, message: message)
  }

  private static func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }
}

extension LocalTurnCheckpoint {
  fileprivate var json: JSONValue {
    .object([
      "round": .int(Int64(round)),
      "messages": .array(messages.map { .object(["role": .string($0.role.rawValue), "content": .string($0.text)]) }),
      "carry": carry,
    ])
  }

  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let round = fields["round"]?.intValue.flatMap({ Int(exactly: $0) }), round >= 1,
      let storedMessages = fields["messages"]?.arrayValue, let carry = fields["carry"]
    else { return nil }
    var messages: [PromptMessage] = []
    for stored in storedMessages {
      guard let entry = stored.objectValue, let role = entry["role"]?.stringValue.flatMap(PromptMessage.Role.init(rawValue:)), role != .system,
        let content = entry["content"]?.stringValue
      else { return nil }
      messages.append(PromptMessage(role, content))
    }
    self.init(round: round, messages: messages, carry: carry)
  }
}
