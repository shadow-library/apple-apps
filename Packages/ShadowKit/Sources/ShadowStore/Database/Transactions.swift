import Foundation
import GRDB
import ShadowCore

public struct ReadTransaction {
  public let database: Database

  let registry: SchemaRegistry

  public func state(of ref: EntityRef, scope: StateScope = .vault) throws(StoreError) -> EntityState? {
    try StateLoader(registry: registry).entity(ref, scope: scope, in: database)
  }

  public func states(ofKind kind: EntityKind, scope: StateScope = .vault) throws(StoreError) -> [(ref: EntityRef, state: EntityState)] {
    try StateLoader(registry: registry).entities(ofKind: kind, scope: scope, in: database)
  }
}

public struct WriteTransaction: ~Copyable {
  /// For the caller's own tables in the same transaction; the kernel's tables must never be written through it.
  public let database: Database
  public private(set) var changes: [ChangeRecord] = []
  private(set) var touched = TouchedRefs()

  let registry: SchemaRegistry
  let clock: HybridLogicalClock
  let ids: UUIDv7Generator

  init(database: Database, registry: SchemaRegistry, clock: HybridLogicalClock, ids: UUIDv7Generator) {
    self.database = database
    self.registry = registry
    self.clock = clock
    self.ids = ids
  }

  public func state(of ref: EntityRef, scope: StateScope = .vault) throws(StoreError) -> EntityState? {
    try StateLoader(registry: registry).entity(ref, scope: scope, in: database)
  }

  public func states(ofKind kind: EntityKind, scope: StateScope = .vault) throws(StoreError) -> [(ref: EntityRef, state: EntityState)] {
    try StateLoader(registry: registry).entities(ofKind: kind, scope: scope, in: database)
  }

  public mutating func set(_ ref: EntityRef, _ fields: [String: JSONValue]) throws(StoreError) -> ChangeRecord {
    if case .appended = try schema(of: ref).shape { throw .invalidChange("kind \(ref.kind) does not take set") }
    return try commit(record(.set, ref, fields))
  }

  public mutating func purge(_ ref: EntityRef) throws(StoreError) -> ChangeRecord {
    _ = try schema(of: ref)
    return try commit(record(.purge, ref, [:]))
  }

  public mutating func append(_ ref: EntityRef, item: [String: JSONValue]) throws(StoreError) -> ChangeRecord {
    guard case .appended = try schema(of: ref).shape else { throw .invalidChange("kind \(ref.kind) does not take append") }
    guard try vaultRow("SELECT 1 FROM appended_item WHERE scope = ? AND kind = ? AND key = ?", ref) == nil else {
      throw .invalidChange("\(ref.kind)/\(ref.key) already holds an item")
    }
    return try commit(record(.append, ref, item))
  }

  public mutating func revise(
    _ ref: EntityRef, body: JSONValue, parent: RevisionParent = .head, head: Bool = true, marks: [String] = []
  ) throws(StoreError) -> (record: ChangeRecord, revision: String) {
    try requireRevisioned(ref)
    let parentID: String?
    switch parent {
    case .head:
      let row = try vaultRow("SELECT value FROM field_state WHERE scope = ? AND kind = ? AND key = ? AND slot = ?", ref, [FieldSlot.head.rawValue])
      parentID = try row.flatMap { row throws(StoreError) in try Stored.json(row.stored("value")).stringValue }
    case .none:
      parentID = nil
    case .revision(let id):
      _ = try storedRevision(ref, id)
      parentID = id
    }
    let highest: Int64? = try vaultRow("SELECT MAX(generation) AS highest FROM revision WHERE scope = ? AND kind = ? AND key = ?", ref)?.stored("highest")
    let generation = highest.map { $0 == Int64.max ? $0 : $0 + 1 } ?? 0
    let created = clock.now()
    let item = RevisionItem(parent: parentID, body: body, created: created, generation: generation)
    let record = ChangeRecord.revise(id: ids.next(), clock: created, schema: registry.version, entity: ref.kind, key: ref.key, item: item, head: head, marks: marks)
    return (try commit(record), item.id)
  }

  public mutating func reassert(_ ref: EntityRef, revision: String, head: Bool, marks: [String] = []) throws(StoreError) -> ChangeRecord {
    try requireRevisioned(ref)
    let item = try storedRevision(ref, revision)
    return try commit(.revise(id: ids.next(), clock: clock.now(), schema: registry.version, entity: ref.kind, key: ref.key, item: item, head: head, marks: marks))
  }

  mutating func apply(_ record: ChangeRecord, scope: StateScope = .vault) throws(StoreError) {
    let merge = MergeRoutine(registry: registry)
    var declared = false
    try savepoint {
      declared = try merge.apply(record, scope: scope, in: database)
      try KernelRow.observe(record.clock, ownReplica: clock.replica, in: database)
    }
    if declared { touched.insert(record.ref, scope: scope) }
    clock.observe(record.clock)
  }

  func keepOpaque(_ line: Data, scope: StateScope = .vault) throws(StoreError) {
    let merge = MergeRoutine(registry: registry)
    try savepoint { try merge.keepOpaque(line, scope: scope, in: database) }
  }

  private func schema(of ref: EntityRef) throws(StoreError) -> EntitySchema {
    guard let schema = registry[ref.kind] else { throw .invalidChange("kind \(ref.kind) is not declared") }
    guard try vaultRow("SELECT 1 FROM tombstone WHERE scope = ? AND kind = ? AND key = ?", ref) == nil else { throw .entityPurged(ref) }
    return schema
  }

  private func requireRevisioned(_ ref: EntityRef) throws(StoreError) {
    guard case .revisioned = try schema(of: ref).shape else { throw .invalidChange("kind \(ref.kind) does not take revise") }
  }

  private func storedRevision(_ ref: EntityRef, _ id: String) throws(StoreError) -> RevisionItem {
    guard let row = try vaultRow("SELECT item FROM revision WHERE scope = ? AND kind = ? AND key = ? AND id = ?", ref, [id]) else { throw .unknownRevision(id) }
    return try Stored.revision(row.stored("item"))
  }

  private func vaultRow(_ sql: String, _ ref: EntityRef, _ extra: StatementArguments = []) throws(StoreError) -> Row? {
    try StoreError.wrapping { try database.storeFetchOne(sql, [StateScope.vault.rawValue, ref.kind.rawValue, ref.key.rawValue] + extra) }
  }

  private func record(_ kind: ChangeKind, _ ref: EntityRef, _ fields: [String: JSONValue]) -> ChangeRecord {
    ChangeRecord(id: ids.next(), clock: clock.now(), schema: registry.version, entity: ref.kind, key: ref.key, kind: kind, fields: fields)
  }

  private mutating func commit(_ record: ChangeRecord) throws(StoreError) -> ChangeRecord {
    guard record.kind != .set || !record.fields.isEmpty else { throw .invalidChange("a set must carry at least one field") }
    guard registry.isInterpretable(record) else { throw .invalidChange("the \(record.kind.rawValue) on \(record.entity) names a field, mark or value the registry does not admit") }
    let line = record.canonicalBytes()
    guard line.count <= VaultStore.maximumChangeBytes else { throw .changeTooLarge(line.count) }
    let merge = MergeRoutine(registry: registry)
    try savepoint {
      for scope in StateScope.allCases { try merge.apply(record, scope: scope, in: database) }
      try database.storeExecute("INSERT INTO change_log (seq, line) VALUES (?, ?)", [try KernelRow.takeSequence(database), line])
    }
    changes.append(record)
    for scope in StateScope.allCases { touched.insert(record.ref, scope: scope) }
    return record
  }

  private func savepoint(_ body: () throws -> Void) throws(StoreError) {
    try StoreError.wrapping {
      try database.inSavepoint {
        try body()
        return .commit
      }
    }
  }
}
