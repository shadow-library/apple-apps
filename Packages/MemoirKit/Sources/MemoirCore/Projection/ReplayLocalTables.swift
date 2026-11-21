import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// The clock of every `mm_command` item the projection has replayed, so a merge finds where a changed or purged command sat and reads only the commands
/// after a checkpoint. Local and unsynced: created by the first write that needs it and dropped with the projection's layout.
enum ReplayCommandIndex {
  static let table = "mm_local_replay_command"
  static let definitions = [
    "CREATE TABLE IF NOT EXISTS mm_local_replay_command (key TEXT PRIMARY KEY, clock TEXT NOT NULL) STRICT, WITHOUT ROWID",
    "CREATE INDEX IF NOT EXISTS mm_local_replay_command_order ON mm_local_replay_command (clock, key)",
  ]

  static func exists(in database: Database) throws -> Bool {
    try database.tableExists(table)
  }

  static func replace(with commands: [ReplayCommand], in database: Database) throws {
    try create(in: database)
    try database.execute(sql: "DELETE FROM \(table)")
    for command in commands { try record(command.ref, clock: command.clock, in: database) }
  }

  static func clock(of ref: EntityRef, in database: Database) throws -> HLCTimestamp? {
    guard try exists(in: database) else { return nil }
    return try String.fetchOne(database, sql: "SELECT clock FROM \(table) WHERE key = ?", arguments: [ref.key.rawValue]).map(timestamp)
  }

  static func record(_ ref: EntityRef, clock: HLCTimestamp?, in database: Database) throws {
    try create(in: database)
    guard let clock else { return try database.execute(sql: "DELETE FROM \(table) WHERE key = ?", arguments: [ref.key.rawValue]) }
    try database.execute(sql: "INSERT OR REPLACE INTO \(table) (key, clock) VALUES (?, ?)", arguments: [ref.key.rawValue, clock.description])
  }

  /// Every indexed command placed after `position`, in replay order. The clock's text sorts as the clock does, and keys compare byte by byte, as
  /// `ReplayPosition` orders them.
  static func refs(after position: ReplayPosition?, in database: Database) throws -> [EntityRef] {
    guard try exists(in: database) else { return [] }
    let rows: [Row]
    if let position {
      rows = try Row.fetchAll(
        database, sql: "SELECT key FROM \(table) WHERE clock > ? OR (clock = ? AND key > ?) ORDER BY clock, key",
        arguments: [position.clock.description, position.clock.description, position.ref.key.rawValue])
    } else {
      rows = try Row.fetchAll(database, sql: "SELECT key FROM \(table) ORDER BY clock, key")
    }
    return try rows.map { row in
      let text: String = row["key"]
      guard let key = EntityKey(text) else { throw StoreError.corruptStore("the replay command index holds the key \(text)") }
      return EntityRef(kind: MemoirKind.command.entityKind, key: key)
    }
  }

  static func drop(in database: Database) throws {
    try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
  }

  private static func create(in database: Database) throws {
    for definition in definitions { try database.execute(sql: definition) }
  }

  private static func timestamp(_ text: String) throws -> HLCTimestamp {
    guard let clock = HLCTimestamp(text) else { throw StoreError.corruptStore("the replay command index holds the clock \(text)") }
    return clock
  }
}

/// `mm_local_replay_checkpoint`: replay states saved where a day closes, keyed by their position. Local and unsynced, created by the first checkpoint
/// written, read only after a `tableExists` check and dropped with the projection's layout.
enum ReplayCheckpointTable {
  static let table = "mm_local_replay_checkpoint"
  static let definition = """
    CREATE TABLE IF NOT EXISTS mm_local_replay_checkpoint (
      clock TEXT NOT NULL, key TEXT NOT NULL, day TEXT NOT NULL, ruleset_version INTEGER NOT NULL, stamp TEXT NOT NULL, body BLOB NOT NULL,
      digest TEXT NOT NULL, PRIMARY KEY (clock, key)
    ) STRICT, WITHOUT ROWID
    """

  struct Entry: Hashable {
    let position: ReplayPosition
    let day: LocalDate
    let digest: String
    let stamp: String
  }

  static func write(_ checkpoint: ReplayCheckpoint, in database: Database) throws {
    try database.execute(sql: definition)
    try database.execute(
      sql: "INSERT OR REPLACE INTO \(table) (clock, key, day, ruleset_version, stamp, body, digest) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [
        checkpoint.position.clock.description, checkpoint.position.ref.key.rawValue, checkpoint.day.isoString, checkpoint.rulesetVersion, checkpoint.stamp,
        checkpoint.body, checkpoint.digest,
      ])
  }

  /// Every row, latest position first; a row whose fields do not parse is deleted, since nothing can resume from it.
  static func entries(in database: Database) throws -> [Entry] {
    guard try database.tableExists(table) else { return [] }
    var entries = [Entry]()
    for row in try Row.fetchAll(database, sql: "SELECT clock, key, day, stamp, digest FROM \(table) ORDER BY clock DESC, key DESC") {
      let clockText: String = row["clock"]
      let keyText: String = row["key"]
      let dayText: String = row["day"]
      guard let clock = HLCTimestamp(clockText), let key = EntityKey(keyText), let day = LocalDate(isoString: dayText) else {
        try database.execute(sql: "DELETE FROM \(table) WHERE clock = ? AND key = ?", arguments: [clockText, keyText])
        continue
      }
      entries.append(
        Entry(position: ReplayPosition(clock: clock, ref: EntityRef(kind: MemoirKind.command.entityKind, key: key)), day: day, digest: row["digest"], stamp: row["stamp"]))
    }
    return entries
  }

  static func checkpoint(at entry: Entry, in database: Database) throws -> ReplayCheckpoint? {
    guard
      let row = try Row.fetchOne(
        database, sql: "SELECT ruleset_version, body FROM \(table) WHERE clock = ? AND key = ?",
        arguments: [entry.position.clock.description, entry.position.ref.key.rawValue])
    else { return nil }
    return ReplayCheckpoint(day: entry.day, position: entry.position, rulesetVersion: row["ruleset_version"], stamp: entry.stamp, body: row["body"], digest: entry.digest)
  }

  static func delete(_ position: ReplayPosition, in database: Database) throws {
    guard try database.tableExists(table) else { return }
    try database.execute(sql: "DELETE FROM \(table) WHERE clock = ? AND key = ?", arguments: [position.clock.description, position.ref.key.rawValue])
  }

  /// A checkpoint at a command's place includes it, so a change there needs one strictly before it.
  static func delete(atOrAfter position: ReplayPosition, in database: Database) throws {
    guard try database.tableExists(table) else { return }
    try database.execute(
      sql: "DELETE FROM \(table) WHERE clock > ? OR (clock = ? AND key >= ?)",
      arguments: [position.clock.description, position.clock.description, position.ref.key.rawValue])
  }

  /// Keeps the `recent` latest rows and the latest row of every month, which bounds the table by the months of history.
  static func prune(keepingRecent recent: Int, in database: Database) throws {
    let entries = try entries(in: database)
    var kept = Set(entries.prefix(recent).map(\.position))
    var months = Set<Int>()
    for entry in entries where months.insert(entry.day.year * 12 + entry.day.month).inserted { kept.insert(entry.position) }
    for entry in entries where !kept.contains(entry.position) { try delete(entry.position, in: database) }
  }

  static func drop(in database: Database) throws {
    try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
  }
}
