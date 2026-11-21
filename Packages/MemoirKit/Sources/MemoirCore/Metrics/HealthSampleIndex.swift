import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The reading device's own copy of the samples it reduced and the anchors it resumes from, in the store of the samples' class: a deletion in Health
/// names only a sample's id, and this index says which day it changes. Nothing in it syncs; it is cleared when the device stops reading
/// (`HealthImport.forgetLocalState`), so a device that takes over starts from Health, not from another device's copy.
enum HealthSampleIndex {
  static let samples = "mm_local_health_sample"
  static let anchors = "mm_local_health_anchor"

  /// A night belongs to the day it ends on, counting an end after 18:00 towards the next day, so the stages of one night land on one day.
  static let sleepDayShiftMillis: Int64 = 6 * 3_600_000

  private static let definitions = [
    """
    CREATE TABLE IF NOT EXISTS mm_local_health_sample (
      kind TEXT NOT NULL, id BLOB NOT NULL, day INTEGER NOT NULL, start_millis INTEGER NOT NULL, end_millis INTEGER NOT NULL, quantity TEXT,
      PRIMARY KEY (kind, id)
    ) STRICT, WITHOUT ROWID
    """,
    "CREATE INDEX IF NOT EXISTS mm_local_health_sample_day ON mm_local_health_sample (kind, day)",
    "CREATE TABLE IF NOT EXISTS mm_local_health_anchor (kind TEXT NOT NULL PRIMARY KEY, anchor BLOB NOT NULL) STRICT, WITHOUT ROWID",
  ]

  private static let millisPerDay: Int64 = 86_400_000
  private static let millisPerMinute: Int64 = 60_000

  static func anchor(of kind: HealthSampleKind, in database: Database) throws(StoreError) -> HealthAnchor? {
    try projecting {
      guard try database.tableExists(anchors) else { return nil }
      let data = try Data.fetchOne(database, sql: "SELECT anchor FROM \(anchors) WHERE kind = ?", arguments: [kind.rawValue])
      return data.map(HealthAnchor.init(data:))
    }
  }

  /// Whether this device has read `total` since it last forgot its state: until it has, a day Health gives no total for keeps what an earlier reader
  /// imported.
  static func hasRead(_ total: HealthTotal, in database: Database) throws(StoreError) -> Bool {
    try projecting {
      guard try database.tableExists(anchors) else { return false }
      return try Bool.fetchOne(database, sql: "SELECT 1 FROM \(anchors) WHERE kind = ?", arguments: [totalKey(total)]) ?? false
    }
  }

  static func markRead(_ total: HealthTotal, in database: Database) throws(StoreError) {
    try projecting {
      for definition in definitions { try database.execute(sql: definition) }
      try database.execute(sql: "INSERT OR REPLACE INTO \(anchors) (kind, anchor) VALUES (?, ?)", arguments: [totalKey(total), Data()])
    }
  }

  /// Applies additions before deletions, so a sample added and deleted since the last anchor ends deleted. Returns the days whose samples changed and the
  /// number of samples left out as malformed.
  static func apply(_ changes: HealthSampleChanges, of kind: HealthSampleKind, in database: Database) throws(StoreError) -> (days: Set<LocalDate>, skipped: Int) {
    try projecting {
      for definition in definitions { try database.execute(sql: definition) }
      var days = Set<LocalDate>()
      var skipped = 0
      for sample in changes.added {
        guard let day = Self.day(of: sample, kind: kind) else {
          skipped += 1
          continue
        }
        if let previous = try existingDay(of: sample.id, kind: kind, in: database) { days.insert(previous) }
        try database.execute(
          sql: "INSERT OR REPLACE INTO \(samples) (kind, id, day, start_millis, end_millis, quantity) VALUES (?, ?, ?, ?, ?, ?)",
          arguments: [kind.rawValue, sample.id, day.daysSinceEpoch, sample.startMillis, sample.endMillis, kind.isInterval ? nil : sample.quantity?.text])
        days.insert(day)
      }
      for id in changes.deleted {
        guard let previous = try existingDay(of: id, kind: kind, in: database) else { continue }
        try database.execute(sql: "DELETE FROM \(samples) WHERE kind = ? AND id = ?", arguments: [kind.rawValue, id])
        days.insert(previous)
      }
      try database.execute(sql: "INSERT OR REPLACE INTO \(anchors) (kind, anchor) VALUES (?, ?)", arguments: [kind.rawValue, changes.anchor.data])
      return (days, skipped)
    }
  }

  /// The day's value: the latest quantity (ties broken by id, so every reader picks the same), or the minutes of the union of the day's intervals, which
  /// counts time two sources recorded at once only once.
  static func summary(of kind: HealthSampleKind, on date: LocalDate, in database: Database) throws(StoreError) -> DecimalText? {
    try projecting {
      guard try database.tableExists(samples) else { return nil }
      let arguments: StatementArguments = [kind.rawValue, date.daysSinceEpoch]
      guard kind.isInterval else {
        let latest = try String.fetchOne(
          database, sql: "SELECT quantity FROM \(samples) WHERE kind = ? AND day = ? ORDER BY start_millis DESC, id DESC LIMIT 1", arguments: arguments)
        return latest.flatMap(DecimalText.init)
      }
      let rows = try Row.fetchAll(database, sql: "SELECT start_millis, end_millis FROM \(samples) WHERE kind = ? AND day = ? ORDER BY start_millis", arguments: arguments)
      guard !rows.isEmpty else { return nil }
      var total: Int64 = 0
      var covered: (start: Int64, end: Int64)?
      for row in rows {
        let start: Int64 = row["start_millis"]
        let end: Int64 = row["end_millis"]
        guard let current = covered, start <= current.end else {
          if let current = covered { total += current.end - current.start }
          covered = (start, end)
          continue
        }
        covered = (current.start, max(current.end, end))
      }
      if let current = covered { total += current.end - current.start }
      return DecimalText(String((total + millisPerMinute / 2) / millisPerMinute))
    }
  }

  static func forget(in database: Database) throws(StoreError) {
    try projecting {
      for table in [samples, anchors] where try database.tableExists(table) { try database.execute(sql: "DELETE FROM \(table)") }
    }
  }

  static func day(of sample: HealthSample, kind: HealthSampleKind) -> LocalDate? {
    guard sample.endMillis >= sample.startMillis else { return nil }
    if !kind.isInterval {
      guard let quantity = sample.quantity, !quantity.text.hasPrefix("-") else { return nil }
    }
    let instant = kind == .sleep ? sample.endMillis.addingReportingOverflow(sleepDayShiftMillis) : (sample.startMillis, false)
    let (local, overflow) = instant.0.addingReportingOverflow(Int64(sample.utcOffsetMinutes) * millisPerMinute)
    guard !instant.1, !overflow else { return nil }
    let quotient = local / millisPerDay
    let day = local % millisPerDay < 0 ? quotient - 1 : quotient
    return Int(exactly: day).flatMap(LocalDate.init(daysSinceEpoch:))
  }

  private static func totalKey(_ total: HealthTotal) -> String { "total." + total.rawValue }

  private static func existingDay(of id: UUID, kind: HealthSampleKind, in database: Database) throws -> LocalDate? {
    try Int.fetchOne(database, sql: "SELECT day FROM \(samples) WHERE kind = ? AND id = ?", arguments: [kind.rawValue, id]).flatMap(LocalDate.init(daysSinceEpoch:))
  }

  private static func projecting<T>(_ body: () throws -> T) throws(StoreError) -> T {
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
}
