import Foundation
import GRDB

enum StoredBytes {
  private static let sources: [(sql: String, arguments: StatementArguments)] = [
    ("SELECT key, value FROM field_state WHERE scope = ?", [StateScope.vault.rawValue]), ("SELECT key, item FROM appended_item WHERE scope = ?", [StateScope.vault.rawValue]),
    ("SELECT key, item FROM revision WHERE scope = ?", [StateScope.vault.rawValue]), ("SELECT bytes FROM foreign_record WHERE scope = ?", [StateScope.vault.rawValue]),
    ("SELECT bytes FROM opaque_line WHERE scope = ?", [StateScope.vault.rawValue]), ("SELECT line FROM \(KernelSchema.changeLogTable)", []),
  ]

  static func visit(_ db: Database, _ body: (Data) throws -> Bool) throws(StoreError) {
    try StoreError.wrapping {
      for (sql, arguments) in sources {
        let rows = try db.storeFetchCursor(sql, arguments)
        while let row = try rows.next() {
          for value in row.databaseValues {
            let proceed: Bool
            switch value.storage {
            case .blob(let data): proceed = try body(data)
            case .string(let text): proceed = try body(Data(text.utf8))
            case .null, .int64, .double: proceed = true
            }
            guard proceed else { return }
          }
        }
      }
    }
  }

  static func hasPendingChanges(_ db: Database) throws(StoreError) -> Bool {
    try StoreError.wrapping { try db.storeFetchOne("SELECT 1 FROM \(KernelSchema.changeLogTable) LIMIT 1", []) != nil }
  }
}

extension ReadTransaction {
  /// Every entity key, field value, appended item and revision of the merged vault state, every record or line of it this registry cannot read, and every
  /// unsent change. The own writes are left out: another replica's purge or overwrite never reaches them. A purged entity leaves only its tombstone, which
  /// is not visited. Stops as soon as `body` returns false.
  public func forEachStoredBytes(_ body: (Data) throws -> Bool) throws(StoreError) {
    try StoredBytes.visit(database, body)
  }

  public func hasPendingChanges() throws(StoreError) -> Bool {
    try StoredBytes.hasPendingChanges(database)
  }

  /// The sequence the newest change was logged under, unsent ones included; 0 before the first.
  public func lastSequence() throws(StoreError) -> Int64 {
    try StoreError.wrapping { try KernelRow.load(database).nextSequence - 1 }
  }
}

extension WriteTransaction {
  public func hasPendingChanges() throws(StoreError) -> Bool {
    try StoredBytes.hasPendingChanges(database)
  }
}
