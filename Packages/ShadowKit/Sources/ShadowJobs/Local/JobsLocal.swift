import Foundation
import GRDB
import ShadowCore
import ShadowStore

public enum LocalStop: String, CaseIterable, Sendable {
  case cancelled
  case stoodDown = "stood_down"

  var settlement: AttemptSettlement {
    switch self {
    case .cancelled: .cancelled
    case .stoodDown: .stoodDown
    }
  }
}

public struct LocalRun: Sendable, Hashable {
  public let attempt: AttemptID
  public let job: EntityRef
  public let replica: ReplicaID
  public let startedAt: Date
  public let stop: LocalStop?
}

/// The input of step `next`, which is the attempt's step `index`.
public struct LocalCheckpoint: Sendable, Hashable {
  public let attempt: AttemptID
  public let index: Int
  public let next: String
  public let state: JSONValue
}

/// A stop mark settles an attempt whose process ended before its outcome at the next launch instead of resuming it.
public enum JobsLocal {
  static let runTable = "jobs_local_run"
  static let checkpointTable = "jobs_local_checkpoint"
  private static let definitions = [
    """
    CREATE TABLE IF NOT EXISTS jobs_local_run (
      attempt BLOB NOT NULL PRIMARY KEY, job TEXT NOT NULL, replica TEXT NOT NULL, started_at INTEGER NOT NULL, stop TEXT, stopped_at INTEGER
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS jobs_local_run_job ON jobs_local_run (job)",
    """
    CREATE TABLE IF NOT EXISTS jobs_local_checkpoint (
      attempt BLOB NOT NULL PRIMARY KEY, step_index INTEGER NOT NULL, next_step TEXT NOT NULL, state BLOB NOT NULL, saved_at INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID
    """,
  ]

  public static func begin(_ run: LocalRun, checkpoint: LocalCheckpoint, at now: Date, in database: Database) throws(StoreError) {
    try execute {
      for definition in definitions { try database.execute(sql: definition) }
      try database.execute(
        sql: "INSERT INTO \(runTable) (attempt, job, replica, started_at) VALUES (?, ?, ?, ?)",
        arguments: [run.attempt.uuid, run.job.key.rawValue, run.replica.description, milliseconds(run.startedAt)])
    }
    try save(checkpoint, at: now, in: database)
  }

  /// False once the run is forgotten.
  @discardableResult
  public static func save(_ checkpoint: LocalCheckpoint, at now: Date, in database: Database) throws(StoreError) -> Bool {
    try execute {
      guard try hasRun(checkpoint.attempt, in: database) else { return false }
      try database.execute(
        sql: "INSERT OR REPLACE INTO \(checkpointTable) (attempt, step_index, next_step, state, saved_at) VALUES (?, ?, ?, ?, ?)",
        arguments: [checkpoint.attempt.uuid, checkpoint.index, checkpoint.next, CanonicalJSON.encode(checkpoint.state), milliseconds(now)])
      return true
    }
  }

  /// Whether `checkpoint` is still the attempt's step here: read in the transaction that commits the step's output, so of two processes that drive one attempt
  /// only the first to commit moves it on.
  public static func holds(_ checkpoint: LocalCheckpoint, in database: Database) throws(StoreError) -> Bool {
    try execute {
      guard try database.tableExists(checkpointTable) else { return false }
      let sql = "SELECT EXISTS (SELECT 1 FROM \(checkpointTable) WHERE attempt = ? AND step_index = ? AND next_step = ?)"
      return try Bool.fetchOne(database, sql: sql, arguments: [checkpoint.attempt.uuid, checkpoint.index, checkpoint.next]) ?? false
    }
  }

  /// Keeps the first mark.
  @discardableResult
  public static func markStopped(_ attempt: AttemptID, as stop: LocalStop, at now: Date, in database: Database) throws(StoreError) -> Bool {
    try execute {
      guard try database.tableExists(runTable) else { return false }
      try database.execute(
        sql: "UPDATE \(runTable) SET stop = ?, stopped_at = ? WHERE attempt = ? AND stop IS NULL", arguments: [stop.rawValue, milliseconds(now), attempt.uuid])
      return try hasRun(attempt, in: database)
    }
  }

  /// In the transaction that records the attempt's outcome, so a settled attempt leaves nothing here.
  public static func forget(_ attempt: AttemptID, in database: Database) throws(StoreError) {
    try execute {
      guard try database.tableExists(runTable) else { return }
      try database.execute(sql: "DELETE FROM \(checkpointTable) WHERE attempt = ?", arguments: [attempt.uuid])
      try database.execute(sql: "DELETE FROM \(runTable) WHERE attempt = ?", arguments: [attempt.uuid])
    }
  }

  /// Runs of another replica (a restored or cloned database, a re-mint) can never be written from here; answers how many runs it removed.
  @discardableResult
  public static func cleanup(keeping replica: ReplicaID, in database: Database) throws(StoreError) -> Int {
    try execute {
      guard try database.tableExists(runTable) else { return 0 }
      var removed = 0
      for row in try Row.fetchAll(database, sql: "SELECT attempt, job, replica, started_at, stop FROM \(runTable)") where LocalRun(row: row)?.replica != replica {
        try database.execute(sql: "DELETE FROM \(runTable) WHERE attempt = ?", arguments: [row["attempt"] as DatabaseValue])
        removed += 1
      }
      try database.execute(sql: "DELETE FROM \(checkpointTable) WHERE attempt NOT IN (SELECT attempt FROM \(runTable))")
      return removed
    }
  }

  public static func run(_ attempt: AttemptID, in database: Database) throws(StoreError) -> LocalRun? {
    try execute {
      guard try database.tableExists(runTable) else { return nil }
      return try Row.fetchOne(database, sql: "SELECT attempt, job, replica, started_at, stop FROM \(runTable) WHERE attempt = ?", arguments: [attempt.uuid])
        .flatMap(LocalRun.init(row:))
    }
  }

  public static func runs(of replica: ReplicaID, in database: Database) throws(StoreError) -> [LocalRun] {
    try execute {
      guard try database.tableExists(runTable) else { return [] }
      return try Row.fetchAll(
        database, sql: "SELECT attempt, job, replica, started_at, stop FROM \(runTable) WHERE replica = ? ORDER BY started_at, attempt", arguments: [replica.description]
      ).compactMap(LocalRun.init(row:))
    }
  }

  public static func checkpoint(_ attempt: AttemptID, in database: Database) throws(StoreError) -> LocalCheckpoint? {
    try execute {
      guard try database.tableExists(checkpointTable) else { return nil }
      let sql = "SELECT step_index, next_step, state FROM \(checkpointTable) WHERE attempt = ?"
      guard let row = try Row.fetchOne(database, sql: sql, arguments: [attempt.uuid]), let index = try? row.decode(Int.self, forColumn: "step_index"),
        let next = try? row.decode(String.self, forColumn: "next_step"), let data = try? row.decode(Data.self, forColumn: "state"),
        let state = try? CanonicalJSON.decode(data)
      else { return nil }
      return LocalCheckpoint(attempt: attempt, index: index, next: next, state: state)
    }
  }

  private static func hasRun(_ attempt: AttemptID, in database: Database) throws -> Bool {
    guard try database.tableExists(runTable) else { return false }
    return try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM \(runTable) WHERE attempt = ?)", arguments: [attempt.uuid]) ?? false
  }

  private static func execute<T>(_ body: () throws -> T) throws(StoreError) -> T {
    do {
      return try body()
    } catch let error as StoreError {
      throw error
    } catch let error as DatabaseError {
      throw .database("SQLite error \(error.extendedResultCode.rawValue): \(error.message ?? "no message")")
    } catch {
      throw .aborted(error)
    }
  }

  static func milliseconds(_ date: Date) -> Int64 {
    Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) ?? 0
  }
}

extension LocalRun {
  fileprivate init?(row: Row) {
    guard let uuid = try? row.decode(UUID.self, forColumn: "attempt"), let attempt = try? AttemptID(uuid),
      let key = (try? row.decode(String.self, forColumn: "job")).flatMap(EntityKey.init),
      let replica = (try? row.decode(String.self, forColumn: "replica")).flatMap(ReplicaID.init),
      let started = try? row.decode(Int64.self, forColumn: "started_at")
    else { return nil }
    let stop = (try? row.decode(String?.self, forColumn: "stop")).flatMap { $0 }
    guard stop == nil || stop.flatMap(LocalStop.init(rawValue:)) != nil else { return nil }
    self.init(
      attempt: attempt, job: EntityRef(kind: JobSchema.jobKind, key: key), replica: replica, startedAt: Date(timeIntervalSince1970: Double(started) / 1000),
      stop: stop.flatMap(LocalStop.init(rawValue:)))
  }
}
