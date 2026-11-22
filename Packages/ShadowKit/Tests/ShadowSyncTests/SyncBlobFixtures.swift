import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

enum BlobFixture {
  static let receipt = ReplicaFixture.kind("receipt")
  static let registry = SyncKernelSchema.registry(
    version: 3, adding: [EntitySchema(kind: receipt, shape: .record(fields: ["image": .register, "removed": .register]), syncClass: .general)])
  static let healthRegistry = SyncFixture.registry
  static let immediate = SyncConfiguration(blobPartBytes: 4096, blobRetention: .zero)

  static func ref(_ name: String) -> EntityRef {
    EntityRef(kind: receipt, key: ReplicaFixture.key(name))
  }

  static func content(_ size: Int, seed: UInt64) -> Data {
    var generator = SeededGenerator(seed: seed)
    return generator.data(count: size)
  }
}

/// Runs a peer's next queued action once its compaction has settled its uploads and before it compacts, the moment a local write can still slip in.
final class BlobCompactionHooks: Sendable {
  private let actions = Mutex<[String: @Sendable () async -> Void]>([:])

  func onNextCompaction(of peer: String, _ action: @escaping @Sendable () async -> Void) {
    actions.withLock { $0[peer] = action }
  }

  func take(_ peer: String) -> (@Sendable () async -> Void)? {
    actions.withLock { $0.removeValue(forKey: peer) }
  }
}

/// Removes its directory when released, so each test's stores and blob folders go with it.
final class BlobDirectory: Sendable {
  let url = FileManager.default.temporaryDirectory.appending(path: "shadow-blobs-\(UUID().uuidString)", directoryHint: .isDirectory)

  func database(_ name: String) -> URL {
    url.appending(path: name, directoryHint: .isDirectory).appending(path: "vault.sqlite")
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

/// Peers on file stores, so each keeps a blob folder, sharing one provider and one keychain.
struct BlobPeers {
  let directory: BlobDirectory
  let provider: any StorageProvider
  let keychain: InMemoryKeychain
  let clock: SyncSettableClock
  let configuration: SyncConfiguration
  let registry: SchemaRegistry
  let sharesKeys: Bool
  let hooks = BlobCompactionHooks()
  var peers: [SyncHarness]

  subscript(index: Int) -> SyncHarness { peers[index] }

  static func make(
    _ count: Int, provider: any StorageProvider = InMemoryStorageProvider(serverClock: { SyncFixture.start }), configuration: SyncConfiguration = BlobFixture.immediate,
    registry: SchemaRegistry = BlobFixture.registry, sharedKey: Bool = true, clock: SyncSettableClock = SyncSettableClock(SyncFixture.start)
  ) async throws -> BlobPeers {
    var peers = BlobPeers(
      directory: BlobDirectory(), provider: provider, keychain: InMemoryKeychain(), clock: clock, configuration: configuration,
      registry: registry, sharesKeys: sharedKey, peers: [])
    for index in 0..<count { try await peers.join("peer\(index)", createsKey: index == 0 || !sharedKey) }
    return peers
  }

  /// Opens (or reopens) the named peer's store and starts its engine; reopening keeps its device marker, so it resumes as the same replica.
  @discardableResult
  mutating func join(_ name: String, createsKey: Bool = false) async throws -> SyncHarness {
    let harness = try open(name)
    if createsKey { _ = try harness.ring.createKey() }
    if sharesKeys { keychain.deliver() }
    _ = try await harness.engine.start()
    peers.append(harness)
    return harness
  }

  func open(_ name: String) throws -> SyncHarness {
    let clock = clock
    let trusted = TrustedClock(wallClock: { clock.now }, monotonic: SyncFixedMonotonic())
    let store = try SyncFixture.open(.file(directory.database(name)), registry: registry, wallClock: SyncEngine.wallClock(preferring: trusted) { clock.now })
    return SyncHarness(
      store: store, provider: provider, keychain: keychain, device: name, configuration: configuration, trustedClock: trusted, wallClock: { clock.now },
      compactionCheckpoint: { [hooks] step async throws(SyncError) in
        if step == .settled, let action = hooks.take(name) { await action() }
      })
  }

  func settle(rounds: Int = 12) async throws {
    for _ in 0..<rounds {
      var changed = false
      for peer in peers {
        let (download, upload) = try await peer.engine.sync()
        if !download.applied.isEmpty || upload != .nothingToUpload { changed = true }
      }
      if !changed { return }
    }
    throw SyncFixtureFailure("the peers did not settle within \(rounds) rounds")
  }
}

extension SyncHarness {
  var blobs: VaultBlobs {
    get throws { try VaultBlobs(store: store) }
  }

  func setImage(_ name: String, _ id: BlobID?) async throws {
    try await store.write { transaction in _ = try transaction.set(BlobFixture.ref(name), ["image": .string(id?.description ?? "")]) }
  }

  func setRemoved(_ name: String, _ removed: Bool) async throws {
    try await store.write { transaction in _ = try transaction.set(BlobFixture.ref(name), ["removed": .bool(removed)]) }
  }

  func images() async throws -> [String: BlobID] {
    try await store.read { transaction in
      var images: [String: BlobID] = [:]
      for (ref, state) in try transaction.states(ofKind: BlobFixture.receipt) {
        guard case .record(let record) = state, let text = record[field: "image"]?.value.stringValue, let id = BlobID(text) else { continue }
        images[ref.key.rawValue] = id
      }
      return images
    }
  }

  func fetched(_ id: BlobID) async throws -> Data {
    try Data(contentsOf: try await engine.fetchBlob(id))
  }

  func blobRow(_ id: BlobID) async throws -> SyncBlobRow? {
    try await store.read { try SyncBlobTable.load(id, in: $0.database) }
  }
}

/// Records every deleted key and can fail puts under a prefix, the way a provider drops writes while it is unreachable.
final class BlobWatchingProvider: StorageProvider {
  let inner: InMemoryStorageProvider
  private let deletedKeys = Mutex<[ObjectKey]>([])
  private let putKeys = Mutex<[ObjectKey]>([])
  private let failingPrefix = Mutex<String?>(nil)

  init(wrapping inner: InMemoryStorageProvider = InMemoryStorageProvider(serverClock: { SyncFixture.start })) {
    self.inner = inner
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  var deleted: [ObjectKey] { deletedKeys.withLock { $0 } }

  var blobPuts: [ObjectKey] { putKeys.withLock { $0 }.filter { $0.hasPrefix(VaultPath.blobsPrefix) } }

  func failPuts(under prefix: String?) {
    failingPrefix.withLock { $0 = prefix }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    putKeys.withLock { $0.append(key) }
    if let prefix = failingPrefix.withLock({ $0 }), key.hasPrefix(prefix) { throw .unavailable("injected failure") }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    deletedKeys.withLock { $0.append(contentsOf: keys) }
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }

  func blobKeys(_ id: BlobID) async throws -> [ObjectKey] {
    try await inner.listAll(prefix: VaultPath.blobPrefix(id.description)).map(\.key)
  }
}
