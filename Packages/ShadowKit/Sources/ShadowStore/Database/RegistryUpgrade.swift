import Foundation
import GRDB
import ShadowCore

/// The row-level checks are a second line: stored rows carry no rule, so only the stored registry can refuse a changed rule that still admits the stored values.
struct RegistryUpgrade {
  private static let reportedProblems = 3

  let registry: SchemaRegistry

  func run(from stored: SchemaRegistry, in db: Database) throws(StoreError) -> TouchedRefs {
    try refuse(registry.incompatibilities(with: stored))
    return try StoreError.wrapping {
      for scope in StateScope.allCases { try refuseIncompatibilities(scope, in: db) }
      var touched = TouchedRefs()
      let retention = RetentionRoutine(registry: registry)
      for scope in StateScope.allCases {
        try reinterpretForeign(scope, touched: &touched, in: db)
        try retention.prune(touched.refs(in: scope), scope: scope, in: db)
        try prune(stricterKinds(than: stored), scope, touched: &touched, in: db)
      }
      return touched
    }
  }

  private func refuse(_ problems: [String]) throws(StoreError) {
    guard !problems.isEmpty else { return }
    let named = problems.prefix(Self.reportedProblems).joined(separator: "; ")
    let more = problems.count > Self.reportedProblems ? "; and \(problems.count - Self.reportedProblems) more" : ""
    throw .incompatibleRegistry(named + more)
  }

  private func stricterKinds(than stored: SchemaRegistry) -> [EntitySchema] {
    registry.schemas.filter { schema in
      guard case .revisioned(_, _, .keepNewest(let count)) = schema.shape else { return false }
      switch stored[schema.kind]?.shape {
      case .revisioned(_, _, .keepAll)?: return true
      case .revisioned(_, _, .keepNewest(let before))?: return count < before
      default: return false
      }
    }
  }

  private func reinterpretForeign(_ scope: StateScope, touched: inout TouchedRefs, in db: Database) throws {
    let merge = MergeRoutine(registry: registry)
    for row in try db.storeFetchAll("SELECT bytes FROM foreign_record WHERE scope = ?", [scope.rawValue]) {
      let bytes: Data = try row.stored("bytes")
      let record = try Stored.record(bytes)
      guard registry.interpretation(of: record).foreign?.canonicalBytes() != bytes else { continue }
      try db.storeExecute("DELETE FROM foreign_record WHERE scope = ? AND bytes = ?", [scope.rawValue, bytes])
      if try merge.apply(record, scope: scope, in: db) { touched.insert(record.ref, scope: scope) }
    }
  }

  private func prune(_ schemas: [EntitySchema], _ scope: StateScope, touched: inout TouchedRefs, in db: Database) throws {
    let retention = RetentionRoutine(registry: registry)
    for schema in schemas {
      guard let count = retention.limit(of: schema.kind) else { continue }
      let rows = try db.storeFetchAll("SELECT key FROM revision WHERE scope = ? AND kind = ? GROUP BY key HAVING COUNT(*) > ?", [scope.rawValue, schema.kind.rawValue, count])
      for row in rows {
        guard let key = EntityKey(try row.stored("key")) else { throw StoreError.corruptStore("a stored entity reference is malformed") }
        let ref = EntityRef(kind: schema.kind, key: key)
        if try retention.prune(ref, keepingNewest: count, scope: scope, in: db) { touched.insert(ref, scope: scope) }
      }
    }
  }

  private func refuseIncompatibilities(_ scope: StateScope, in db: Database) throws {
    let kinds = try db.storeFetchAll(
      "SELECT kind FROM field_state WHERE scope = ?1 UNION SELECT kind FROM appended_item WHERE scope = ?1 UNION SELECT kind FROM revision WHERE scope = ?1 UNION SELECT kind FROM tombstone WHERE scope = ?1",
      [scope.rawValue])
    for row in kinds {
      guard let kind = EntityKind(try row.stored("kind")) else { throw StoreError.corruptStore("a stored entity reference is malformed") }
      guard let schema = registry[kind] else { throw StoreError.incompatibleRegistry("kind \(kind) is no longer declared") }
      try refuseShapeChange(schema, scope, in: db)
      try refuseUndeclaredFields(schema, scope, in: db)
      try refuseUndeclaredMarks(schema, scope, in: db)
    }
  }

  private func refuseShapeChange(_ schema: EntitySchema, _ scope: StateScope, in db: Database) throws {
    let stored: [(shape: String, sql: String)] = [
      ("record", "SELECT key FROM field_state WHERE scope = ? AND kind = ? AND slot = \(FieldSlot.field.rawValue) LIMIT 1"),
      ("appended", "SELECT key FROM appended_item WHERE scope = ? AND kind = ? LIMIT 1"),
      ("revisioned", "SELECT key FROM revision WHERE scope = ? AND kind = ? LIMIT 1"),
      ("revisioned", "SELECT key FROM field_state WHERE scope = ? AND kind = ? AND slot IN (\(FieldSlot.head.rawValue), \(FieldSlot.mark.rawValue)) LIMIT 1"),
    ]
    let admitted: [String] =
      switch schema.shape {
      case .record: ["record"]
      case .appended: ["appended"]
      case .revisioned: ["record", "revisioned"]
      }
    for (shape, sql) in stored where !admitted.contains(shape) {
      guard let row = try db.storeFetchOne(sql, [scope.rawValue, schema.kind.rawValue]) else { continue }
      let key: String = try row.stored("key")
      throw StoreError.incompatibleRegistry("\(schema.kind)/\(key) is \(shape) but the kind is declared \(schema.shape.name)")
    }
  }

  private func refuseUndeclaredFields(_ schema: EntitySchema, _ scope: StateScope, in db: Database) throws {
    let entity: StatementArguments = [scope.rawValue, schema.kind.rawValue, FieldSlot.field.rawValue]
    for row in try db.storeFetchAll("SELECT DISTINCT name FROM field_state WHERE scope = ? AND kind = ? AND slot = ?", entity) {
      let nameBytes: Data = try row.stored("name")
      let name = try Stored.name(from: nameBytes)
      guard let rule = schema.rule(forField: name) else { throw StoreError.incompatibleRegistry("field \(schema.kind).\(name) is no longer declared") }
      guard case .monotone = rule else { continue }
      for valueRow in try db.storeFetchAll("SELECT value FROM field_state WHERE scope = ? AND kind = ? AND slot = ? AND name = ?", entity + [nameBytes]) {
        guard rule.admits(try Stored.json(valueRow.stored("value"))) else {
          throw StoreError.incompatibleRegistry("field \(schema.kind).\(name) holds a value that \(rule.summary) does not admit")
        }
      }
    }
  }

  private func refuseUndeclaredMarks(_ schema: EntitySchema, _ scope: StateScope, in db: Database) throws {
    let marks = try db.storeFetchAll(
      "SELECT DISTINCT name FROM field_state WHERE scope = ? AND kind = ? AND slot = ?", [scope.rawValue, schema.kind.rawValue, FieldSlot.mark.rawValue])
    for row in marks {
      let name = try Stored.name(from: row.stored("name"))
      guard schema.declaresMark(name) else { throw StoreError.incompatibleRegistry("mark \(schema.kind).\(name) is no longer declared") }
    }
  }
}
