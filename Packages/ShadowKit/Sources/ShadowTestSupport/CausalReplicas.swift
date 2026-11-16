import Foundation
import ShadowCore
import ShadowStore
import Synchronization

public enum CausalReplicaOrder: Sendable {
  case causal
  case writerOrderOnly
}

public enum CausalReplicaError: Error, Equatable, Sendable {
  case noReplicas
  case undecodableChange(replica: Int)
}

public struct CausalReplicaSetup: Sendable {
  public var count: Int
  public var registry: SchemaRegistry
  public var migrations: [StoreMigration]
  public var reconciler: @Sendable (_ index: Int) -> (any StoreReconciler)?
  public var order: CausalReplicaOrder
  public var seed: UInt64

  public init(
    count: Int, registry: SchemaRegistry, migrations: [StoreMigration] = [], order: CausalReplicaOrder = .causal,
    reconciler: @escaping @Sendable (Int) -> (any StoreReconciler)? = { _ in nil }, seed: UInt64 = 0
  ) {
    self.count = count
    self.registry = registry
    self.migrations = migrations
    self.order = order
    self.reconciler = reconciler
    self.seed = seed
  }
}

public struct CausalReplicaDelivery: Sendable, Equatable {
  public let writer: Int
  public let reader: Int
  public let first: Int
  public let count: Int
  public let isRedelivery: Bool
}

final class CausalReplicaClock: Sendable {
  static let start = Date(timeIntervalSince1970: 1_700_000_000)

  private let date = Mutex(CausalReplicaClock.start)

  var now: Date {
    date.withLock { $0 }
  }

  func advance(by seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

struct CausalReplicaChange: Sendable {
  let line: Data
  let record: ChangeRecord
  let dependencies: [Int]
}

/// Not safe to drive concurrently: write and deliver suspend, so interleaved calls can mis-stamp dependency vectors or move applied counts backwards. Use one task.
public actor CausalReplicas {
  public nonisolated let count: Int
  let order: CausalReplicaOrder
  let stores: [VaultStore]
  let clocks: [CausalReplicaClock]
  var streams: [[CausalReplicaChange]]
  var applied: [[Int]]
  var log: [CausalReplicaDelivery] = []

  public init(_ setup: CausalReplicaSetup) async throws {
    guard setup.count > 0 else { throw CausalReplicaError.noReplicas }
    let clocks = (0..<setup.count).map { _ in CausalReplicaClock() }
    count = setup.count
    order = setup.order
    self.clocks = clocks
    var identity = SeededGenerator(seed: setup.seed)
    var opened = [VaultStore]()
    for index in 0..<setup.count {
      let store = try VaultStore.open(.inMemory, registry: setup.registry, migrations: setup.migrations, wallClock: { clocks[index].now }, reconciler: setup.reconciler(index))
      try await store.remint(to: ReplicaID(UUID.v7(at: CausalReplicaClock.start, using: &identity)), mode: .keepState)
      opened.append(store)
    }
    stores = opened
    streams = Array(repeating: [], count: setup.count)
    applied = Array(repeating: Array(repeating: 0, count: setup.count), count: setup.count)
  }

  public func store(_ index: Int) -> VaultStore {
    stores[index]
  }

  public func advanceClock(of index: Int, by duration: Duration) {
    let parts = duration.components
    clocks[index].advance(by: Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
  }

  public func write<T: Sendable>(_ index: Int, _ body: @Sendable (inout WriteTransaction) throws -> T) async throws -> T {
    let store = stores[index]
    let result = try await store.write(body)
    let pending = try await store.pendingChanges(limit: Int.max)
    guard let last = pending.last else { return result }
    var dependencies = applied[index]
    dependencies[index] = streams[index].count
    var batch = [CausalReplicaChange]()
    for change in pending {
      guard let json = try? CanonicalJSON.decode(change.line, mode: .canonical), let record = try? ChangeRecord(json: json) else {
        throw CausalReplicaError.undecodableChange(replica: index)
      }
      batch.append(CausalReplicaChange(line: change.line, record: record, dependencies: dependencies))
    }
    streams[index].append(contentsOf: batch)
    applied[index][index] = streams[index].count
    try await store.dropChanges(through: last.sequence)
    return result
  }

  public func dependencies(writer: Int, index: Int) -> [Int] {
    streams[writer][index].dependencies
  }

  public func appliedCount(reader: Int, writer: Int) -> Int {
    applied[reader][writer]
  }

  public func deliveries() -> [CausalReplicaDelivery] {
    log
  }

  public func isSettled() -> Bool {
    for reader in 0..<count {
      for writer in 0..<count where applied[reader][writer] != streams[writer].count { return false }
    }
    return true
  }

  public func records() -> [ChangeRecord] {
    streams.flatMap { $0.map(\.record) }
  }
}
