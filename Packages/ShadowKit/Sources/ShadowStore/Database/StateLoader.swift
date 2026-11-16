import Foundation
import GRDB
import ShadowCore

struct StateLoader {
  private struct Parts {
    var tombstone: HLCTimestamp?
    var fields: [ExactString: FieldState] = [:]
    var head: FieldState?
    var marks: [ExactString: FieldState] = [:]
    var revisions: [ExactString: RevisionItem] = [:]
    var appended: AppendedState?

    var isEmptyBesideTombstone: Bool {
      fields.isEmpty && head == nil && marks.isEmpty && revisions.isEmpty && appended == nil
    }
  }

  let registry: SchemaRegistry

  func state(_ scope: StateScope, in db: Database) throws(StoreError) -> VaultState {
    try StoreError.wrapping {
      var state = VaultState()
      for (ref, parts) in try parts(scope, nil, in: db) { state.entities[ref] = try entity(ref, parts) }
      for row in try db.storeFetchAll("SELECT bytes, kind, key, role FROM foreign_record WHERE scope = ?", [scope.rawValue]) {
        let bytes: Data = try row.stored("bytes")
        state.foreignRecords[bytes] = try foreign(row, bytes)
      }
      try verifyForeignBesidePurges(state)
      for row in try db.storeFetchAll("SELECT bytes FROM opaque_line WHERE scope = ?", [scope.rawValue]) { state.opaque.insert(try row.stored("bytes")) }
      return state
    }
  }

  func entity(_ ref: EntityRef, scope: StateScope, in db: Database) throws(StoreError) -> EntityState? {
    try StoreError.wrapping { try parts(scope, ref, in: db)[ref].map { try entity(ref, $0) } }
  }

  private func parts(_ scope: StateScope, _ ref: EntityRef?, in db: Database) throws -> [EntityRef: Parts] {
    let filter = ref == nil ? "" : " AND kind = ? AND key = ?"
    let arguments: StatementArguments = ref.map { [scope.rawValue, $0.kind.rawValue, $0.key.rawValue] } ?? [scope.rawValue]
    var parts = [EntityRef: Parts]()
    func rows(_ columns: String, _ table: String, _ body: (Row, inout Parts) throws -> Void) throws {
      for row in try db.storeFetchAll("SELECT kind, key, \(columns) FROM \(table) WHERE scope = ?\(filter)", arguments) {
        try body(row, &parts[try Self.ref(row), default: Parts()])
      }
    }
    try rows("clock", "tombstone") { row, parts in parts.tombstone = try Stored.clock(row.stored("clock")) }
    try rows("item, clock", "appended_item") { row, parts in
      parts.appended = AppendedState(item: try Stored.object(row.stored("item")), clock: try Stored.clock(row.stored("clock")))
    }
    try rows("id, item", "revision") { row, parts in
      let id = ExactString(try row.stored("id"))
      let item = try Stored.revision(row.stored("item"))
      guard ExactString(item.id) == id else { throw StoreError.corruptStore("a stored revision does not match its id") }
      parts.revisions[id] = item
    }
    try rows("slot, name, value, clock", "field_state") { row, parts in
      let name = try Stored.name(from: row.stored("name"))
      let field = FieldState(value: try Stored.json(row.stored("value")), clock: try Stored.clock(row.stored("clock")), rule: .register)
      switch FieldSlot(rawValue: try row.stored("slot")) {
      case .field: parts.fields[ExactString(name)] = field
      case .head: parts.head = field
      case .mark: parts.marks[ExactString(name)] = field
      case nil: throw StoreError.corruptStore("a stored field slot is unknown")
      }
    }
    return parts
  }

  private func entity(_ ref: EntityRef, _ parts: Parts) throws(StoreError) -> EntityState {
    if let tombstone = parts.tombstone {
      guard parts.isEmptyBesideTombstone else { throw .corruptStore("\(ref.kind)/\(ref.key) holds state beside its tombstone") }
      return .purged(PurgedState(clock: tombstone))
    }
    guard let schema = registry[ref.kind] else { throw .corruptStore("state is stored for the undeclared kind \(ref.kind)") }
    var fields = [ExactString: FieldState]()
    for (name, field) in parts.fields {
      guard let rule = schema.rule(forField: name.value), rule.admits(field.value) else {
        throw .corruptStore("\(ref.kind).\(name) is not declared or holds a value its rule does not admit")
      }
      fields[name] = FieldState(value: field.value, clock: field.clock, rule: rule)
    }
    switch schema.shape {
    case .record:
      guard parts.head == nil, parts.marks.isEmpty, parts.revisions.isEmpty, parts.appended == nil else { throw .corruptStore("\(ref.kind) holds state of another shape") }
      guard !fields.isEmpty else { throw .corruptStore("\(ref.kind)/\(ref.key) holds no fields") }
      return .record(RecordState(fields: fields))
    case .appended:
      guard fields.isEmpty, parts.head == nil, parts.marks.isEmpty, parts.revisions.isEmpty else { throw .corruptStore("\(ref.kind) holds state of another shape") }
      guard let appended = parts.appended else { throw .corruptStore("\(ref.kind)/\(ref.key) holds no item") }
      return .appended(appended)
    case .revisioned:
      guard parts.appended == nil else { throw .corruptStore("\(ref.kind) holds state of another shape") }
      guard parts.marks.keys.allSatisfy({ schema.declaresMark($0.value) }) else { throw .corruptStore("\(ref.kind) holds an undeclared mark") }
      let pointers = [parts.head].compactMap(\.self) + Array(parts.marks.values)
      guard pointers.allSatisfy({ $0.value.stringValue != nil }) else { throw .corruptStore("\(ref.kind) holds a head or mark that is not a revision id") }
      let state = RevisionedState(fields: fields, head: parts.head, marks: parts.marks, revisions: parts.revisions)
      guard !state.isEmpty, state.namedRevisions.isSubset(of: state.revisions.keys) else { throw .corruptStore("\(ref.kind)/\(ref.key) names a revision it does not hold") }
      return .revisioned(state)
    }
  }

  private func foreign(_ row: Row, _ bytes: Data) throws -> ChangeRecord {
    let record = try Stored.record(bytes)
    let role: Int = try row.stored("role")
    guard record.canonicalBytes() == bytes, ForeignRole(record).rawValue == role, record.ref == (try Self.ref(row)) else {
      throw StoreError.corruptStore("a stored foreign record does not match its bytes, role or entity")
    }
    return record
  }

  private func verifyForeignBesidePurges(_ state: VaultState) throws(StoreError) {
    let absorbed = Set(state.foreignRecords.values.filter(\.absorbsForeign).map(\.ref))
    for record in state.foreignRecords.values where record.kind != .purge && (absorbed.contains(record.ref) || state.entities[record.ref]?.isPurged == true) {
      throw .corruptStore("a foreign record of the purged \(record.entity)/\(record.key) is kept")
    }
  }

  private static func ref(_ row: Row) throws -> EntityRef {
    guard let kind = EntityKind(try row.stored("kind")), let key = EntityKey(try row.stored("key")) else {
      throw StoreError.corruptStore("a stored entity reference is malformed")
    }
    return EntityRef(kind: kind, key: key)
  }
}
