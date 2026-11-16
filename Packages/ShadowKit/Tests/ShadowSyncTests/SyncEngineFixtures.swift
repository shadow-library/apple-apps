import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import ShadowSync

struct SyncFixtureFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

struct SyncFixedMonotonic: MonotonicTimeSource {
  func nanoseconds() -> UInt64 { 0 }
}

final class SyncSettableClock: Sendable {
  private let current: Mutex<Date>

  init(_ date: Date) {
    current = Mutex(date)
  }

  var now: Date { current.withLock { $0 } }

  func set(_ date: Date) {
    current.withLock { $0 = date }
  }
}

enum SyncFixture {
  static let vault = ReplicaFixture.vault
  static let note = ReplicaFixture.note
  static let vital = ReplicaFixture.kind("vital")
  static let registry = SyncKernelSchema.registry(
    version: 3,
    adding: [
      EntitySchema(kind: note, shape: .record(fields: ["title": .register]), syncClass: .general),
      EntitySchema(kind: vital, shape: .record(fields: ["value": .register]), syncClass: .health),
    ])
  static let start = ReplicaFixture.start
  static let crash = SyncError.corruptState("injected crash")

  static func keyID(_ index: Int) -> KeyID {
    guard let id = KeyID(String(format: "00000000-0000-7000-8000-%012x", index)) else { preconditionFailure("fixture key id is valid") }
    return id
  }

  static func open(_ location: StoreLocation = .inMemory, wallClock: @escaping @Sendable () -> Date = { start }) throws -> VaultStore {
    try VaultStore.open(location, registry: registry, migrations: SyncEngine.migrations, wallClock: wallClock)
  }
}

struct SyncHarness {
  let store: VaultStore
  let provider: any StorageProvider
  let keychain: InMemoryKeychain
  let ring: KeyRing
  let lifecycle: ReplicaLifecycle
  let trustedClock: TrustedClock
  let engine: SyncEngine

  init(
    store: VaultStore,
    provider: any StorageProvider,
    keychain: InMemoryKeychain = InMemoryKeychain(),
    configuration: SyncConfiguration = .init(),
    trustedClock: TrustedClock = TrustedClock(wallClock: { SyncFixture.start }, monotonic: SyncFixedMonotonic()),
    wallClock: @escaping @Sendable () -> Date = { SyncFixture.start },
    crashAt step: SyncUploadStep? = nil,
    lifecycleCrashAt lifecycleStep: ReplicaLifecycleStep? = nil,
    publicFloor: @escaping @Sendable () -> HLCTimestamp? = { nil },
    markerStore: (any SecureStore)? = nil
  ) {
    self.store = store
    self.provider = provider
    self.keychain = keychain
    self.trustedClock = trustedClock
    let device = keychain.device("phone")
    ring = KeyRing(vault: SyncFixture.vault, store: device.store(service: "keys", scope: .synced))
    let lifecycleCheckpoint: @Sendable (ReplicaLifecycleStep) throws(ReplicaLifecycleError) -> Void = { reached throws(ReplicaLifecycleError) in
      if reached == lifecycleStep { throw ReplicaFixture.crash }
    }
    lifecycle = ReplicaLifecycle(
      store: store, vault: SyncFixture.vault, marker: DeviceMarker(store: markerStore ?? device.store(service: "marker", scope: .device)), device: ReplicaFixture.phone,
      wallClock: wallClock, makeReplicaID: { ReplicaID(UUID.v7()) }, checkpoint: lifecycleCheckpoint)
    let checkpoint: @Sendable (SyncUploadStep) throws(SyncError) -> Void = { reached throws(SyncError) in
      if reached == step { throw SyncFixture.crash }
    }
    engine = SyncEngine(
      store: store, provider: provider, vault: SyncFixture.vault, ring: ring, lifecycle: lifecycle, trustedClock: trustedClock, configuration: configuration,
      wallClock: wallClock, publicFloor: { publicFloor() }, checkpoint: checkpoint)
  }

  static func started(
    store: VaultStore? = nil,
    provider: any StorageProvider = InMemoryStorageProvider(),
    keychain: InMemoryKeychain = InMemoryKeychain(),
    configuration: SyncConfiguration = .init(),
    withKey: Bool = true,
    crashAt step: SyncUploadStep? = nil,
    lifecycleCrashAt lifecycleStep: ReplicaLifecycleStep? = nil
  ) async throws -> SyncHarness {
    let harness = SyncHarness(
      store: try store ?? SyncFixture.open(), provider: provider, keychain: keychain, configuration: configuration, crashAt: step, lifecycleCrashAt: lifecycleStep)
    if withKey { _ = try harness.ring.createKey() }
    _ = try await harness.engine.start()
    return harness
  }

  func writeNotes(_ count: Int, prefix: String = "n", title: (Int) -> String = { "Title \($0)" }) async throws {
    let titles = (0..<count).map(title)
    try await store.write { transaction in
      for (index, title) in titles.enumerated() {
        _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("\(prefix)\(index)")), ["title": .string(title)])
      }
    }
  }

  func pendingLines() async throws -> [Data] {
    try await store.pendingChanges(limit: Int.max).map(\.line)
  }

  func savedFloors() async throws -> SyncFloors {
    try await store.read { try SyncFloorTable.load($0.database) }
  }

  func raiseDirectoryFloors(key: KeyID? = nil, schema: Int? = nil) async throws {
    let directory = try await lifecycle.directory()
    try await store.write { transaction in
      if let key { try directory.raiseKeyFloor(to: key, in: &transaction) }
      if let schema { try directory.raiseSchemaFloor(to: schema, in: &transaction) }
    }
  }

  func history() async throws -> ReplicaUploadHistory {
    let replica = store.replica
    return try await store.read { try ReplicaHistory.uploads(of: replica, in: $0.database) }
  }

  func savedUpload() async throws -> SyncOutboxEntry? {
    try await store.read { try SyncOutbox.load($0.database) }
  }

  func recordApplied(_ point: StreamPoint, of replica: ReplicaID) async throws {
    try await store.write { transaction in
      try SyncAppliedTable.record(point, first: 1, isBase: false, replica: replica, at: 1, in: transaction.database)
    }
  }

  func segments(of replica: ReplicaID? = nil) async throws -> [SyncStoredSegment] {
    try await SyncStoredSegment.all(in: provider, prefix: replica.map(VaultPath.segmentPrefix) ?? VaultPath.replicasPrefix, ring: ring)
  }
}

struct SyncStoredSegment {
  let key: ObjectKey
  let point: StreamPoint
  let data: Data
  let file: SegmentFile

  static func all(in provider: any StorageProvider, prefix: String, ring: KeyRing) async throws -> [SyncStoredSegment] {
    var segments: [SyncStoredSegment] = []
    for object in try await provider.listAll(prefix: prefix) {
      guard case .segment(_, _, let last, let tag) = VaultPath.classify(object.key) else { continue }
      let data = try await provider.get(object.key)
      let file = try SegmentCodec.open(data, at: object.key, vault: SyncFixture.vault) { ring.key($0) }
      segments.append(SyncStoredSegment(key: object.key, point: StreamPoint(last: last, tag: tag), data: data, file: file))
    }
    return segments.sorted { ($0.file.header.first, $0.key) < ($1.file.header.first, $1.key) }
  }
}

enum SyncChain {
  /// Every sequence 1...count is in exactly one file, the files chain by `previous`, and the history knows exactly these files.
  static func verify(_ segments: [SyncStoredSegment], count: Int64, history: ReplicaUploadHistory) throws {
    var expected: Int64 = 1
    var previous: StreamPoint?
    for segment in segments {
      let header = segment.file.header
      guard header.first == expected else { throw SyncFixtureFailure("segment \(segment.key) starts at \(header.first), expected \(expected)") }
      guard header.previous == previous else { throw SyncFixtureFailure("segment \(segment.key) does not chain to \(String(describing: previous))") }
      expected = header.last + 1
      previous = segment.point
    }
    guard expected == count + 1 else { throw SyncFixtureFailure("storage covers 1...\(expected - 1), expected 1...\(count)") }
    guard Set(segments.map(\.point)) == history.segments else { throw SyncFixtureFailure("the history differs from storage") }
  }
}

final class SyncRecordingProvider: StorageProvider {
  private let inner: InMemoryStorageProvider
  private let log = Mutex<[String]>([])

  init(wrapping inner: InMemoryStorageProvider) {
    self.inner = inner
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  var operations: [String] { log.withLock { $0 } }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    log.withLock { $0.append("list \(prefix)") }
    return try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    log.withLock { $0.append("put \(key)") }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

final class SyncFlakySecureStore: SecureStore {
  private let inner: any SecureStore
  private let readsBeforeFailure = Mutex<Int?>(nil)

  init(wrapping inner: any SecureStore) {
    self.inner = inner
  }

  func failReads(after count: Int) {
    readsBeforeFailure.withLock { $0 = count }
  }

  func heal() {
    readsBeforeFailure.withLock { $0 = nil }
  }

  func data(forKey key: String) throws(SecureStoreError) -> Data? {
    let fails = readsBeforeFailure.withLock { remaining -> Bool in
      guard let count = remaining else { return false }
      remaining = count - 1
      return count <= 0
    }
    if fails { throw .unexpectedStatus(-25308) }
    return try inner.data(forKey: key)
  }

  func setData(_ data: Data, forKey key: String) throws(SecureStoreError) {
    try inner.setData(data, forKey: key)
  }

  func insertData(_ data: Data, forKey key: String) throws(SecureStoreError) -> Bool {
    try inner.insertData(data, forKey: key)
  }

  func removeValue(forKey key: String) throws(SecureStoreError) {
    try inner.removeValue(forKey: key)
  }

  func allKeys() throws(SecureStoreError) -> [String] {
    try inner.allKeys()
  }
}

final class SyncLateServerTimeProvider: StorageProvider {
  private let inner: InMemoryStorageProvider
  private let serverTime: Date
  private let reporting = Mutex(false)

  init(wrapping inner: InMemoryStorageProvider, serverTime: Date) {
    self.inner = inner
    self.serverTime = serverTime
  }

  var capabilities: StorageCapabilities {
    let base = inner.capabilities
    return StorageCapabilities(
      pushesChangeNotices: base.pushesChangeNotices, supportsPutIfAbsent: base.supportsPutIfAbsent, hasChangeFeed: base.hasChangeFeed, reportsServerTime: true,
      maxObjectBytes: base.maxObjectBytes, classPolicy: base.classPolicy)
  }

  func startReportingServerTime() {
    reporting.withLock { $0 = true }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    _ = try await inner.put(key, data: data, condition: condition)
    return PutReceipt(serverTime: reporting.withLock { $0 } ? serverTime : nil)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}
