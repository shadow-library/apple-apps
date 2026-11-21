import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import ShadowSync
@testable import ShadowSyncRuntime

/// Three devices sharing one keychain and one vault, first synced through `old`; each holds its database across engines, as an app does across a move.
final class MoveWorld: Sendable {
  static let vault = RuntimeFixture.vault("move-vault")
  static let vital = RuntimeFixture.kind("vital")
  static let registry = SyncKernelSchema.registry(
    version: 1,
    adding: [
      EntitySchema(kind: RuntimeFixture.note, shape: .record(fields: ["title": .register]), syncClass: .general),
      EntitySchema(kind: vital, shape: .record(fields: ["value": .register]), syncClass: .health),
    ])

  let keychain = InMemoryKeychain()
  let folders: TemporaryDirectory
  let old: any StorageProvider
  let new: any StorageProvider
  let oldLocation: SyncLocation
  let newLocation: SyncLocation
  let devices: [MoveDevice]

  init(old: (any StorageProvider)? = nil, new: (any StorageProvider)? = nil, offsets: [Duration] = []) throws {
    folders = try TemporaryDirectory()
    let oldURL = folders.url.appending(path: "old", directoryHint: .isDirectory)
    let newURL = folders.url.appending(path: "new", directoryHint: .isDirectory)
    self.old = try old ?? LocalFolderProvider(root: oldURL)
    self.new = try new ?? LocalFolderProvider(root: newURL)
    oldLocation = SyncLocation(settings: .localFolder(SyncLocalFolderSettings(url: oldURL)), vault: Self.vault, account: nil)
    newLocation = SyncLocation(settings: .localFolder(SyncLocalFolderSettings(url: newURL)), vault: Self.vault, account: nil)
    let keychain = keychain
    devices = try ["mover", "follower", "third"].enumerated().map { index, name in
      try MoveDevice(name: name, keychain: keychain, offset: index < offsets.count ? offsets[index] : .zero)
    }
  }

  var mover: MoveDevice { devices[0] }
  var follower: MoveDevice { devices[1] }
  var third: MoveDevice { devices[2] }

  /// Every device has written a note and read everyone else's through the old location.
  static func synced(old: (any StorageProvider)? = nil, new: (any StorageProvider)? = nil, offsets: [Duration] = []) async throws -> MoveWorld {
    let world = try MoveWorld(old: old, new: new, offsets: offsets)
    _ = try world.mover.ring.createKey()
    world.keychain.deliver()
    for device in world.devices {
      try device.locations.save(world.oldLocation)
      try await device.write("\(device.name)-early", "written by \(device.name)")
    }
    var engines: [SyncEngine] = []
    for device in world.devices { engines.append(try await device.started(on: world.old)) }
    try await world.settle(engines)
    return world
  }

  func mover(
    _ device: MoveDevice? = nil, engine: SyncEngine, target: SyncLocation? = nil, targetProvider: (any StorageProvider)? = nil, crashAt step: SyncMoveStep? = nil,
    sourceProvider: (any StorageProvider)? = nil
  ) -> SyncMover {
    let device = device ?? mover
    return SyncMover(
      engine: engine, ring: device.ring, source: oldLocation, sourceProvider: sourceProvider ?? old, target: target ?? newLocation, targetProvider: targetProvider ?? new,
      locations: device.locations,
      checkpoint: { reached throws(SyncMoveError) in
        if reached == step { throw .journal("injected crash") }
      })
  }

  func follower(
    _ device: MoveDevice, engine: SyncEngine, target: SyncLocation? = nil, targetProvider: (any StorageProvider)? = nil, crashAt step: SyncMoveFollowStep? = nil
  ) -> SyncMoveFollower {
    SyncMoveFollower(engine: engine, source: oldLocation, target: target ?? newLocation, targetProvider: targetProvider ?? new, locations: device.locations) {
      reached throws(SyncMoveError) in
      if reached == step { throw .journal("injected crash") }
    }
  }

  /// Downloads in the old location until the notice shows, follows it, and returns the device's engine in the new location.
  func follow(_ device: MoveDevice, from engine: SyncEngine) async throws -> SyncEngine {
    guard let notice = try await engine.download().moved else { throw RuntimeFixtureFailure("\(device.name) did not see the move notice") }
    guard case .moved = try await follower(device, engine: engine).run(notice) else { throw RuntimeFixtureFailure("\(device.name) did not follow") }
    return try await device.started(on: new)
  }

  func settle(_ engines: [SyncEngine], rounds: Int = 3) async throws {
    for _ in 0..<rounds {
      for engine in engines { _ = try await engine.sync() }
    }
  }

  func snapshot(of provider: any StorageProvider) async throws -> [ObjectKey: Data] {
    var files: [ObjectKey: Data] = [:]
    for object in try await provider.listAll(prefix: "") where VaultPath.classify(object.key) != .unknown {
      files[object.key] = try await provider.get(object.key)
    }
    return files
  }
}

struct MoveDevice: Sendable {
  let name: String
  let store: VaultStore
  let ring: KeyRing
  let marker: any SecureStore
  let directory: TemporaryDirectory
  let locations: SyncLocationStore
  let offset: ClockOffset
  let trustedClock: TrustedClock
  let deviceClock: @Sendable () -> Date

  init(name: String, keychain: InMemoryKeychain, offset: Duration) throws {
    self.name = name
    let device = keychain.device(name)
    let shift = ClockOffset(offset)
    self.offset = shift
    let deviceClock: @Sendable () -> Date = { Date().addingTimeInterval(shift.seconds) }
    self.deviceClock = deviceClock
    trustedClock = TrustedClock(wallClock: deviceClock)
    store = try VaultStore.open(
      .inMemory, registry: MoveWorld.registry, migrations: SyncEngine.migrations, wallClock: SyncEngine.wallClock(preferring: trustedClock, device: deviceClock))
    ring = KeyRing(vault: MoveWorld.vault, store: device.store(service: RuntimeFixture.ringService, scope: .synced))
    marker = device.store(service: "com.shadow.apps.test.sync.device", scope: .device)
    directory = try TemporaryDirectory()
    locations = try directory.locationStore()
  }

  var journal: SyncMoveJournalStore { SyncMoveJournalStore(beside: locations) }

  func attachment(_ location: SyncLocation, provider: any StorageProvider) -> SyncAttachment {
    SyncAttachment(location: location, provider: provider, providerID: 1, ring: ring, markerStore: marker, keyServices: SyncKeyServices())
  }

  func started(
    on provider: any StorageProvider, moveCheckpoint: @escaping @Sendable (SyncMoveKernelStep) async throws(SyncError) -> Void = { _ async throws(SyncError) in }
  ) async throws -> SyncEngine {
    let lifecycle = ReplicaLifecycle(
      store: store, vault: MoveWorld.vault, marker: DeviceMarker(store: marker), device: ReplicaDevice(name: name, platform: "iOS", appVersion: "1.0"),
      wallClock: deviceClock)
    let store = store
    let engine = SyncEngine(
      store: store, provider: provider, vault: MoveWorld.vault, ring: ring, lifecycle: lifecycle, trustedClock: trustedClock, configuration: SyncConfiguration(),
      wallClock: deviceClock, publicFloor: { () async throws(SyncError) in try? await store.publicClockFloor() }, checkpoint: { _ throws(SyncError) in },
      moveCheckpoint: moveCheckpoint)
    _ = try await engine.start()
    return engine
  }

  func setOffset(_ offset: Duration) {
    self.offset.set(offset)
  }

  func forgetMarker() throws {
    try DeviceMarker(store: marker).clear(vault: MoveWorld.vault)
  }

  func write(_ key: String, _ title: String) async throws {
    guard let entity = EntityKey(key) else { throw RuntimeFixtureFailure("\(key) is not an entity key") }
    try await store.write { transaction in _ = try transaction.set(EntityRef(kind: RuntimeFixture.note, key: entity), ["title": .string(title)]) }
  }

  func titles() async throws -> [String: String] {
    let notes = try await store.read { try $0.states(ofKind: RuntimeFixture.note) }
    var titles: [String: String] = [:]
    for (ref, state) in notes {
      guard case .record(let record) = state, let title = record[field: "title"]?.value.stringValue else { continue }
      titles[ref.key.rawValue] = title
    }
    return titles
  }
}

/// Hands out a corrupted copy of the named files, as storage that fails to deliver one object to one device.
final class CorruptingReadProvider: StorageProvider {
  private let inner: any StorageProvider
  private let corrupted: Set<ObjectKey>

  init(wrapping inner: any StorageProvider, corrupting corrupted: Set<ObjectKey>) {
    self.inner = inner
    self.corrupted = corrupted
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    var data = try await inner.get(key)
    if corrupted.contains(key) { data[data.index(before: data.endIndex)] ^= 0x01 }
    return data
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

final class ClockOffset: Sendable {
  private let value: Mutex<Duration>

  init(_ value: Duration) {
    self.value = Mutex(value)
  }

  var seconds: TimeInterval { Double(value.withLock { $0 }.components.seconds) }

  func set(_ value: Duration) {
    self.value.withLock { $0 = value }
  }
}

/// Changes the bytes of the first `count` base parts it stores, as a provider that corrupts or forges a copy would.
final class TamperingProvider: StorageProvider {
  let inner: InMemoryStorageProvider
  private let remaining: Mutex<Int>

  init(inner: InMemoryStorageProvider = InMemoryStorageProvider(), count: Int) {
    self.inner = inner
    remaining = Mutex(count)
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard Self.isBasePart(key), takeOne() else { return try await inner.put(key, data: data, condition: condition) }
    var forged = data
    forged[forged.index(forged.endIndex, offsetBy: -1)] ^= 0x01
    return try await inner.put(key, data: forged, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }

  private static func isBasePart(_ key: ObjectKey) -> Bool {
    guard case .basePart = VaultPath.classify(key) else { return false }
    return true
  }

  private func takeOne() -> Bool {
    remaining.withLock { count in
      guard count > 0 else { return false }
      count -= 1
      return true
    }
  }
}
