import Foundation
import GRDB
import ShadowCore

/// The SQL form of `VaultState.apply(_:registry:)`: it touches only the rows the record concerns and decides every conflict with the model's own joins.
struct MergeRoutine {
  let registry: SchemaRegistry

  func apply(_ record: ChangeRecord, scope: StateScope, in db: Database) throws(StoreError) {
    try StoreError.wrapping {
      let rows = EntityRows(db: db, scope: scope, ref: record.ref)
      let interpretation = registry.interpretation(of: record)
      let tombstone = try rows.tombstone()
      switch interpretation.state {
      case .purged(let purge)?: try rows.purge(purge, joining: tombstone)
      case let state? where tombstone == nil: try rows.write(state)
      default: break
      }
      if let remainder = interpretation.foreign { try rows.keepForeign(remainder, purged: tombstone != nil) }
    }
  }

  func keepOpaque(_ line: Data, scope: StateScope, in db: Database) throws(StoreError) {
    try StoreError.wrapping {
      try db.storeExecute("INSERT OR IGNORE INTO opaque_line (scope, bytes) VALUES (?, ?)", [scope.rawValue, line])
    }
  }
}

private struct EntityRows {
  let db: Database
  let scope: StateScope
  let ref: EntityRef

  private var entity: StatementArguments { [scope.rawValue, ref.kind.rawValue, ref.key.rawValue] }

  func tombstone() throws -> PurgedState? {
    guard let row = try db.storeFetchOne("SELECT clock FROM tombstone WHERE scope = ? AND kind = ? AND key = ?", entity) else { return nil }
    return PurgedState(clock: try Stored.clock(row.stored("clock")))
  }

  func purge(_ purge: PurgedState, joining existing: PurgedState?) throws {
    guard let existing else {
      try db.storeExecute("INSERT INTO tombstone (scope, kind, key, clock) VALUES (?, ?, ?, ?)", entity + [purge.clock.description])
      for table in ["field_state", "appended_item", "revision"] { try db.storeExecute("DELETE FROM \(table) WHERE scope = ? AND kind = ? AND key = ?", entity) }
      try dropForeign()
      return
    }
    guard case .purged(let joined) = EntityState.purged(existing).joined(with: .purged(purge)), joined != existing else { return }
    try db.storeExecute("UPDATE tombstone SET clock = ? WHERE scope = ? AND kind = ? AND key = ?", [joined.clock.description] + entity)
  }

  func write(_ state: EntityState) throws {
    switch state {
    case .record(let record):
      for (name, field) in record.fields { try join(field, slot: .field, name: name.value) }
    case .revisioned(let revisioned):
      for (name, field) in revisioned.fields { try join(field, slot: .field, name: name.value) }
      if let head = revisioned.head { try join(head, slot: .head, name: EntitySchema.headField) }
      for (name, mark) in revisioned.marks { try join(mark, slot: .mark, name: name.value) }
      for (id, item) in revisioned.revisions {
        try db.storeExecute(
          "INSERT OR IGNORE INTO revision (scope, kind, key, id, item, generation) VALUES (?, ?, ?, ?, ?, ?)", entity + [id.value, item.canonicalBytes, item.generation])
      }
    case .appended(let appended):
      try join(appended)
    case .purged:
      break
    }
  }

  func keepForeign(_ record: ChangeRecord, purged: Bool) throws {
    let role = ForeignRole(record)
    if role == .droppable {
      guard !purged else { return }
      let absorbing = try db.storeFetchOne(
        "SELECT 1 FROM foreign_record WHERE scope = ? AND kind = ? AND key = ? AND role = ? LIMIT 1", entity + [ForeignRole.absorbing.rawValue])
      guard absorbing == nil else { return }
    }
    try db.storeExecute(
      "INSERT OR IGNORE INTO foreign_record (scope, bytes, kind, key, role) VALUES (?, ?, ?, ?, ?)",
      [scope.rawValue, record.canonicalBytes(), ref.kind.rawValue, ref.key.rawValue, role.rawValue])
    if role == .absorbing { try dropForeign() }
  }

  private func dropForeign() throws {
    try db.storeExecute("DELETE FROM foreign_record WHERE scope = ? AND kind = ? AND key = ? AND role = ?", entity + [ForeignRole.droppable.rawValue])
  }

  private func join(_ incoming: FieldState, slot: FieldSlot, name: String) throws {
    let key = entity + [slot.rawValue, Stored.name(name)]
    guard let row = try db.storeFetchOne("SELECT value, clock FROM field_state WHERE scope = ? AND kind = ? AND key = ? AND slot = ? AND name = ?", key) else {
      try db.storeExecute(
        "INSERT INTO field_state (scope, kind, key, slot, name, value, clock) VALUES (?, ?, ?, ?, ?, ?, ?)",
        key + [CanonicalJSON.encode(incoming.value), incoming.clock.description])
      return
    }
    let stored = FieldState(value: try Stored.json(row.stored("value")), clock: try Stored.clock(row.stored("clock")), rule: incoming.rule)
    let joined = stored.joined(with: incoming)
    guard joined != stored else { return }
    try db.storeExecute(
      "UPDATE field_state SET value = ?, clock = ? WHERE scope = ? AND kind = ? AND key = ? AND slot = ? AND name = ?",
      [CanonicalJSON.encode(joined.value), joined.clock.description] + key)
  }

  private func join(_ incoming: AppendedState) throws {
    guard let row = try db.storeFetchOne("SELECT item, clock FROM appended_item WHERE scope = ? AND kind = ? AND key = ?", entity) else {
      try db.storeExecute(
        "INSERT INTO appended_item (scope, kind, key, item, clock) VALUES (?, ?, ?, ?, ?)", entity + [CanonicalJSON.encode(.object(incoming.item)), incoming.clock.description])
      return
    }
    let stored = AppendedState(item: try Stored.object(row.stored("item")), clock: try Stored.clock(row.stored("clock")))
    let joined = stored.joined(with: incoming)
    guard joined != stored else { return }
    try db.storeExecute(
      "UPDATE appended_item SET item = ?, clock = ? WHERE scope = ? AND kind = ? AND key = ?", [CanonicalJSON.encode(.object(joined.item)), joined.clock.description] + entity)
  }
}
