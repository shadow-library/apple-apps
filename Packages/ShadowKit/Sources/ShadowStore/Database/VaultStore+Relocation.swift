import Foundation
import GRDB
import ShadowCore

extension VaultStore {
  /// Joins the whole vault scope into this replica's own writes, so its bases carry everything; running it again changes nothing.
  public func adoptVaultState(also body: @Sendable (Database) throws -> Void = { _ in }) async throws(StoreError) {
    let registry = registry
    try await writing { db in
      try body(db)
      let state = try StateLoader(registry: registry).state(.vault, in: db)
      let merge = MergeRoutine(registry: registry)
      var touched = TouchedRefs()
      for record in state.records(schema: registry.version) {
        if try merge.apply(record, scope: .own, in: db) { touched.insert(record.ref, scope: .own) }
      }
      for line in state.opaqueLines { try merge.keepOpaque(line, scope: .own, in: db) }
      try self.settlement.prune(touched, in: db)
    }
  }

  /// Relays, as unsent changes kept unchanged through any re-mint, each vault record of a kind `admits` accepts whose clock is above the `frontier` entry of
  /// the replica that stamped it, or that a replica absent from `frontier` stamped, in clock order and leaving state untouched. A record still pending here,
  /// a line without a clock and a kind this registry does not declare are left out.
  public func requeue(
    above frontier: [ReplicaID: HLCTimestamp], admitting admits: @Sendable (EntitySchema) -> Bool, also body: @Sendable (Database) throws -> Void = { _ in }
  ) async throws(StoreError) -> Int {
    let registry = registry
    return try await writing { db in
      try body(db)
      var pending: Set<HLCTimestamp> = []
      for row in try db.storeFetchAll("SELECT line FROM change_log", []) { pending.insert(try Stored.record(row.stored("line")).clock) }
      let state = try StateLoader(registry: registry).state(.vault, in: db)
      let relayed = state.records(schema: registry.version).filter { record in
        guard let schema = registry[record.entity], admits(schema), !pending.contains(record.clock) else { return false }
        return frontier[record.clock.replica].map { record.clock > $0 } ?? true
      }
      for record in relayed.sorted(by: { $0.clock < $1.clock }) {
        try db.storeExecute("INSERT INTO change_log (seq, line, relayed) VALUES (?, ?, 1)", [try KernelRow.takeSequence(db), record.canonicalBytes()])
      }
      return relayed.count
    }
  }

}
