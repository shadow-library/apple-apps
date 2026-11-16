import Foundation
import GRDB
import ShadowCore

public struct OwnSnapshot: Sendable, Equatable {
  public let replica: ReplicaID
  public let upTo: Int64
  public let schema: Int
  public let lines: [Data]
}

extension VaultStore {
  public func ownSnapshot() async throws(StoreError) -> OwnSnapshot {
    let registry = registry
    return try await reading { db in
      let row = try KernelRow.load(db)
      let state = try StateLoader(registry: registry).state(.own, in: db)
      let records = state.records(schema: registry.version)
      let lines = records.map { $0.canonicalBytes() } + state.opaqueLines
      return OwnSnapshot(replica: row.replica, upTo: row.nextSequence - 1, schema: records.map(\.schema).max() ?? registry.version, lines: lines)
    }
  }
}
