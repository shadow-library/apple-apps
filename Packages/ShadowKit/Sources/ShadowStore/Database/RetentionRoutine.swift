import GRDB
import ShadowCore

/// The SQL form of `VaultState.retained(registry:)` for one entity: it reads the cut-off through the `revision_rank` index and never loads the revisions.
struct RetentionRoutine {
  let registry: SchemaRegistry

  func limit(of kind: EntityKind) -> Int? {
    guard case .revisioned(_, _, .keepNewest(let count))? = registry[kind]?.shape else { return nil }
    return count
  }

  func prune(_ refs: Set<EntityRef>, scope: StateScope, in db: Database) throws(StoreError) {
    for ref in refs {
      guard let count = limit(of: ref.kind) else { continue }
      try prune(ref, keepingNewest: count, scope: scope, in: db)
    }
  }

  @discardableResult
  func prune(_ ref: EntityRef, keepingNewest count: Int, scope: StateScope, in db: Database) throws(StoreError) -> Bool {
    try StoreError.wrapping {
      let entity: StatementArguments = [scope.rawValue, ref.kind.rawValue, ref.key.rawValue]
      guard
        let cutoff = try db.storeFetchOne(
          "SELECT generation, id FROM revision WHERE scope = ? AND kind = ? AND key = ? ORDER BY generation DESC, id DESC LIMIT 1 OFFSET ?", entity + [max(count, 1) - 1])
      else { return false }
      let generation: Int64 = try cutoff.stored("generation")
      let id: String = try cutoff.stored("id")
      var named = [String]()
      for row in try db.storeFetchAll(
        "SELECT value FROM field_state WHERE scope = ? AND kind = ? AND key = ? AND slot IN (?, ?)", entity + [FieldSlot.head.rawValue, FieldSlot.mark.rawValue])
      {
        if let revision = try Stored.json(row.stored("value")).stringValue { named.append(revision) }
      }
      let exclusion = named.isEmpty ? "" : " AND id NOT IN (\(Array(repeating: "?", count: named.count).joined(separator: ", ")))"
      try db.storeExecute(
        "DELETE FROM revision WHERE scope = ? AND kind = ? AND key = ? AND (generation, id) < (?, ?)\(exclusion)", entity + [generation, id] + StatementArguments(named))
      return db.changesCount > 0
    }
  }
}
