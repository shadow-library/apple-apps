import Foundation
import GRDB

/// The main store's record that a restore has begun, committed on its own before any store imports and dropped inside the main store's import, which
/// commits last. Found with data in a store but none in main, it says the other stores committed and main did not: the vault is half restored.
/// `mm_local_restore_pending` is created by the write that marks it and read only after a `tableExists` check.
enum RestorePending {
  static let table = "mm_local_restore_pending"

  static func mark(atMillis millis: Int64, in database: Database) throws {
    try database.execute(sql: "CREATE TABLE IF NOT EXISTS \(table) (id INTEGER PRIMARY KEY CHECK (id = 1), started_at_millis INTEGER NOT NULL) STRICT")
    try database.execute(sql: "INSERT OR REPLACE INTO \(table) (id, started_at_millis) VALUES (1, ?)", arguments: [millis])
  }

  static func isMarked(in database: Database) throws -> Bool {
    guard try database.tableExists(table) else { return false }
    return try Bool.fetchOne(database, sql: "SELECT EXISTS (SELECT 1 FROM \(table))") == true
  }

  static func clear(in database: Database) throws {
    try database.execute(sql: "DROP TABLE IF EXISTS \(table)")
  }
}
