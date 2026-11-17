import GRDB
import ShadowCore

extension ReadTransaction {
  /// The merged value of the named fields of every live entity of a kind in the vault scope, unsorted and without loading whole entities: for an aggregate
  /// over many records that needs few of their fields. An undeclared kind reads as empty, as in `states(ofKind:)`; an undeclared field name is refused.
  package func fieldValues(ofKind kind: EntityKind, named names: [String]) throws(StoreError) -> [EntityKey: [String: JSONValue]] {
    guard let schema = registry[kind] else { return [:] }
    if let undeclared = names.first(where: { schema.rule(forField: $0) == nil }) { throw .invalidChange("\(kind).\(undeclared) is not a declared field") }
    guard !names.isEmpty else { return [:] }
    let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")
    let arguments: StatementArguments = [StateScope.vault.rawValue, kind.rawValue, FieldSlot.field.rawValue] + StatementArguments(names.map(Stored.name))
    let sql = "SELECT key, name, value FROM field_state WHERE scope = ? AND kind = ? AND slot = ? AND name IN (\(placeholders))"
    return try StoreError.wrapping {
      var values: [EntityKey: [String: JSONValue]] = [:]
      let rows = try database.storeFetchCursor(sql, arguments)
      while let row = try rows.next() {
        guard let key = EntityKey(try row.stored("key")) else { throw StoreError.corruptStore("a stored entity key is malformed") }
        values[key, default: [:]][try Stored.name(from: row.stored("name"))] = try Stored.json(row.stored("value"))
      }
      return values
    }
  }
}
