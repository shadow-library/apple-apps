import Foundation
import GRDB
import ShadowCore
import Synchronization

public final class VaultStore: Sendable {
  public static let maximumChangeBytes = 4 * 1024 * 1024

  public let registry: SchemaRegistry
  let storedRegistryVersion: Int

  private let writer: any DatabaseWriter
  private let wallClock: @Sendable () -> Date
  private let ids: UUIDv7Generator
  private let clock: Mutex<HybridLogicalClock?>
  private let currentReplica: Mutex<ReplicaID>

  private init(writer: any DatabaseWriter, registry: SchemaRegistry, row: KernelRow, wallClock: @escaping @Sendable () -> Date) {
    self.writer = writer
    self.registry = registry
    storedRegistryVersion = row.registryVersion
    self.wallClock = wallClock
    ids = UUIDv7Generator(wallClock: wallClock)
    clock = Mutex(nil)
    currentReplica = Mutex(row.replica)
  }

  public var replica: ReplicaID {
    currentReplica.withLock { $0 }
  }

  public static func open(
    _ location: StoreLocation, registry: SchemaRegistry, migrations: [StoreMigration] = [], wallClock: @escaping @Sendable () -> Date = { Date() }
  ) throws(StoreError) -> VaultStore {
    let migrator = try KernelSchema.migrator(migrations)
    return try StoreError.wrapping {
      var configuration = Configuration()
      configuration.label = "ShadowStore"
      configuration.busyMode = .timeout(5)
      let writer: any DatabaseWriter
      switch location {
      case .file(let url):
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path(percentEncoded: false), configuration: configuration)
      case .inMemory:
        writer = try DatabaseQueue(configuration: configuration)
      }
      try migrator.migrate(writer)
      let row = try writer.write { db in try KernelRow.prepare(db, registryVersion: registry.version) { ReplicaID(UUID.v7(at: wallClock())) } }
      return VaultStore(writer: writer, registry: registry, row: row, wallClock: wallClock)
    }
  }

  public func read<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws(StoreError) -> T {
    let registry = registry
    return try await reading { db in try body(ReadTransaction(database: db, registry: registry)) }
  }

  public func write<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(StoreError) -> T {
    try await writing { db in
      let row = try KernelRow.load(db)
      var transaction = WriteTransaction(database: db, registry: self.registry, clock: self.clock(for: row), ids: self.ids)
      let result = try body(&transaction)
      if let latest = transaction.clock.latest, latest != row.clock { try KernelRow.saveClock(latest, in: db) }
      return result
    }
  }

  public func loadState(_ scope: StateScope) async throws(StoreError) -> VaultState {
    let loader = StateLoader(registry: registry)
    return try await reading { db in try loader.state(scope, in: db) }
  }

  public func pendingChanges(limit: Int) async throws(StoreError) -> [LoggedChange] {
    try await reading { db in
      try db.storeFetchAll("SELECT seq, line FROM change_log ORDER BY seq LIMIT ?", [max(limit, 0)]).map { row throws(StoreError) in
        LoggedChange(sequence: try row.stored("seq"), line: try row.stored("line"))
      }
    }
  }

  public func dropChanges(through sequence: Int64) async throws(StoreError) {
    try await writing { db in
      let dropped = try db.storeFetchAll("SELECT line FROM change_log WHERE seq <= ?", [sequence]).map { row throws(StoreError) in try Stored.record(row.stored("line")).clock }
      try db.storeExecute("DELETE FROM change_log WHERE seq <= ?", [sequence])
      if let highest = dropped.max() { try KernelRow.acknowledge(highest, in: db) }
    }
  }

  public func remint(to newReplica: ReplicaID, mode: RemintMode, also body: @Sendable (Database) throws -> Void = { _ in }) async throws(StoreError) {
    try await writing { db in
      var row = try KernelRow.load(db)
      guard row.replica != newReplica else { throw StoreError.replicaReused(newReplica) }
      let pending = try db.storeFetchAll("SELECT line FROM change_log ORDER BY seq", []).map { row throws(StoreError) in try Stored.record(row.stored("line")) }
      let merge = MergeRoutine(registry: self.registry)
      let relogged: [ChangeRecord]
      switch mode {
      case .keepState:
        try KernelSchema.clear(.own, in: db)
        for record in pending { try merge.apply(record, scope: .own, in: db) }
        relogged = pending
      case .rebuild:
        for scope in StateScope.allCases { try KernelSchema.clear(scope, in: db) }
        let clock = HybridLogicalClock(replica: newReplica, wallClock: self.wallClock, latest: row.rebuildFloor)
        relogged = pending.map { ChangeRecord(id: self.ids.next(), clock: clock.now(), schema: $0.schema, entity: $0.entity, key: $0.key, kind: $0.kind, fields: $0.fields) }
        for record in relogged { for scope in StateScope.allCases { try merge.apply(record, scope: scope, in: db) } }
        row.clock = clock.latest
      }
      try db.execute(sql: "DELETE FROM change_log")
      for (index, record) in relogged.enumerated() { try db.storeExecute("INSERT INTO change_log (seq, line) VALUES (?, ?)", [index + 1, record.canonicalBytes()]) }
      row.replica = newReplica
      row.nextSequence = Int64(relogged.count) + 1
      try row.saveIdentity(db)
      try body(db)
    }
    currentReplica.withLock { $0 = newReplica }
  }

  private func clock(for row: KernelRow) -> HybridLogicalClock {
    let clock = clock.withLock { cached in
      if let cached, cached.replica == row.replica { return cached }
      let fresh = HybridLogicalClock(replica: row.replica, wallClock: wallClock, latest: row.clock)
      cached = fresh
      return fresh
    }
    for floor in [row.clock, row.observed].compactMap(\.self) { clock.observe(floor) }
    return clock
  }

  private func reading<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(StoreError) -> T {
    do {
      return try await writer.read(body)
    } catch {
      throw StoreError(converting: error)
    }
  }

  private func writing<T: Sendable>(_ body: @Sendable (Database) throws -> T) async throws(StoreError) -> T {
    do {
      return try await writer.write(body)
    } catch {
      throw StoreError(converting: error)
    }
  }
}
