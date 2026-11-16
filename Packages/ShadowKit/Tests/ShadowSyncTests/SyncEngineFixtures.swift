import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

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
  static let message = ReplicaFixture.kind("message")
  static let draft = ReplicaFixture.kind("draft")
  static let entities = [
    EntitySchema(kind: note, shape: .record(fields: ["title": .register]), syncClass: .general),
    EntitySchema(kind: vital, shape: .record(fields: ["value": .register]), syncClass: .health),
  ]
  static let registry = SyncKernelSchema.registry(version: 3, adding: entities)
  static let richRegistry = SyncKernelSchema.registry(
    version: 3,
    adding: entities + [
      EntitySchema(kind: message, shape: .appended, syncClass: .general),
      EntitySchema(kind: draft, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(2)), syncClass: .general),
    ])
  static let start = ReplicaFixture.start
  static let crash = SyncError.corruptState("injected crash")

  static func keyID(_ index: Int) -> KeyID {
    guard let id = KeyID(String(format: "00000000-0000-7000-8000-%012x", index)) else { preconditionFailure("fixture key id is valid") }
    return id
  }

  static func open(
    _ location: StoreLocation = .inMemory, registry: SchemaRegistry = registry, wallClock: @escaping @Sendable () -> Date = { start }
  ) throws -> VaultStore {
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
    device deviceName: String = "phone",
    configuration: SyncConfiguration = .init(),
    trustedClock: TrustedClock = TrustedClock(wallClock: { SyncFixture.start }, monotonic: SyncFixedMonotonic()),
    wallClock: @escaping @Sendable () -> Date = { SyncFixture.start },
    crashAt step: SyncUploadStep? = nil,
    downloadCrashAt downloadStep: SyncDownloadStep? = nil,
    lifecycleCrashAt lifecycleStep: ReplicaLifecycleStep? = nil,
    publicFloor: @escaping @Sendable () -> HLCTimestamp? = { nil },
    markerStore: (any SecureStore)? = nil
  ) {
    self.store = store
    self.provider = provider
    self.keychain = keychain
    self.trustedClock = trustedClock
    let device = keychain.device(deviceName)
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
    let downloadCheckpoint: @Sendable (SyncDownloadStep) throws(SyncError) -> Void = { reached throws(SyncError) in
      if reached == downloadStep { throw SyncFixture.crash }
    }
    engine = SyncEngine(
      store: store, provider: provider, vault: SyncFixture.vault, ring: ring, lifecycle: lifecycle, trustedClock: trustedClock, configuration: configuration,
      wallClock: wallClock, publicFloor: { publicFloor() }, checkpoint: checkpoint, downloadCheckpoint: downloadCheckpoint)
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

  func digest() async throws -> String {
    try await store.loadState(.vault).digest
  }

  func appliedFiles() async throws -> [ReplicaID: SyncAppliedFiles] {
    try await store.read { try SyncAppliedTable.load($0.database) }
  }

  func heldFiles() async throws -> [SyncFileID: SyncHeldFile] {
    try await store.read { try SyncHeldTable.load($0.database) }
  }

  func uploaded() async throws -> [StreamPoint] {
    guard case .uploaded(let points) = try await engine.upload() else { throw SyncFixtureFailure("nothing was uploaded") }
    return points
  }

  func segmentIDs(_ points: [StreamPoint], of replica: ReplicaID? = nil) -> [SyncFileID] {
    points.map { SyncFileID(replica: replica ?? store.replica, kind: .segment, point: $0) }
  }
}

/// Replicas that share one provider and one keychain, each with its own store, device marker and key ring.
struct SyncPeers {
  let provider: any StorageProvider
  let keychain: InMemoryKeychain
  let clock: SyncSettableClock
  let peers: [SyncHarness]

  subscript(index: Int) -> SyncHarness { peers[index] }

  static func make(
    _ count: Int,
    provider: any StorageProvider = InMemoryStorageProvider(),
    configuration: SyncConfiguration = .init(),
    registries: [SchemaRegistry]? = nil,
    clocks: [SyncSettableClock]? = nil,
    sharedKey: Bool = true
  ) async throws -> SyncPeers {
    let keychain = InMemoryKeychain()
    let shared = SyncSettableClock(SyncFixture.start)
    var peers: [SyncHarness] = []
    for index in 0..<count {
      let clock = clocks?[index] ?? shared
      let trusted = TrustedClock(wallClock: { clock.now }, monotonic: SyncFixedMonotonic())
      let store = try SyncFixture.open(registry: registries?[index] ?? SyncFixture.registry, wallClock: SyncEngine.wallClock(preferring: trusted) { clock.now })
      peers.append(
        SyncHarness(
          store: store, provider: provider, keychain: keychain, device: "peer\(index)", configuration: configuration, trustedClock: trusted, wallClock: { clock.now }))
    }
    if sharedKey {
      _ = try peers[0].ring.createKey()
      keychain.deliver()
    } else {
      for peer in peers { _ = try peer.ring.createKey() }
    }
    for peer in peers { _ = try await peer.engine.start() }
    return SyncPeers(provider: provider, keychain: keychain, clock: shared, peers: peers)
  }

  /// Syncs every peer in turn until a full round applies and uploads nothing.
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

/// Hides keys from listings and reads, the way a provider shows recent files late, and fails reads of chosen keys.
final class SyncHidingProvider: StorageProvider {
  private let inner: InMemoryStorageProvider
  private let hidden = Mutex<[String]>([])
  private let failing = Mutex<[ObjectKey: StorageError]>([:])
  private let reads = Mutex<[ObjectKey: Int]>([:])

  init(wrapping inner: InMemoryStorageProvider) {
    self.inner = inner
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  var gets: Int { inner.callCounts.get }

  func hide(_ prefix: String) {
    hidden.withLock { $0.append(prefix) }
  }

  func hide(_ key: ObjectKey) {
    hide(key.rawValue)
  }

  func reveal() {
    hidden.withLock { $0 = [] }
  }

  func fail(_ key: ObjectKey, with error: StorageError?) {
    failing.withLock { $0[key] = error }
  }

  func gets(of key: ObjectKey) -> Int {
    reads.withLock { $0[key] ?? 0 }
  }

  private func isHidden(_ key: ObjectKey) -> Bool {
    hidden.withLock { prefixes in prefixes.contains { key.hasPrefix($0) } }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let page = try await inner.list(prefix: prefix, after: cursor)
    return ListPage(objects: page.objects.filter { !isHidden($0.key) }, next: page.next)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    reads.withLock { $0[key, default: 0] += 1 }
    guard !isHidden(key) else { throw .notFound(key) }
    if let error = failing.withLock({ $0[key] }) { throw error }
    return try await inner.get(key)
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

enum SyncPlant {
  static func segment(
    _ lines: [Data], replica: ReplicaID, first: Int64 = 1, previous: StreamPoint? = nil, dependencies: [ReplicaID: StreamPoint] = [:], key: VaultKey,
    in provider: any StorageProvider
  ) async throws -> SealedFile {
    guard let header = SegmentHeader(replica: replica, first: first, last: first + Int64(lines.count) - 1, previous: previous, dependencies: dependencies, schema: 3),
      let file = SegmentFile(header: header, lines: lines)
    else { throw SyncFixtureFailure("the planted segment is invalid") }
    let sealed = try SegmentCodec.seal(file, vault: SyncFixture.vault, with: key)
    _ = try await provider.put(sealed.key, data: sealed.data, condition: .overwrite)
    return sealed
  }

  /// A base of `harness`'s own writes so far, recorded in its upload history as compaction will; the parts are returned, not put.
  static func base(of harness: SyncHarness, through: StreamPoint?, partPayloadBytes: Int = BaseCodec.defaultPartPayloadBytes) async throws -> [SealedFile] {
    try harness.ring.refresh()
    let snapshot = try await harness.store.ownSnapshot()
    guard let header = BaseHeader(replica: snapshot.replica, upTo: snapshot.upTo, through: through, schema: snapshot.schema) else {
      throw SyncFixtureFailure("the base header is invalid: up to \(snapshot.upTo) through \(String(describing: through))")
    }
    guard let file = BaseFile(header: header, lines: snapshot.lines), let key = harness.ring.writingKey() else { throw SyncFixtureFailure("the base is invalid") }
    let parts = try BaseCodec.seal(file, vault: SyncFixture.vault, with: key, partPayloadBytes: partPayloadBytes)
    let point = StreamPoint(last: snapshot.upTo, tag: try #require(parts.first).tag)
    try await harness.store.write { transaction in
      try ReplicaHistory.recordBase(point, parts: parts.count, replica: snapshot.replica, at: 1, in: transaction.database)
    }
    return parts
  }

  static func records(in provider: any StorageProvider, ring: KeyRing) async throws -> [ChangeRecord] {
    try await SyncStoredSegment.all(in: provider, prefix: VaultPath.replicasPrefix, ring: ring).flatMap(\.file.lines).map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
  }

  static func baseRecords(in provider: any StorageProvider, ring: KeyRing) async throws -> [ChangeRecord] {
    var parts: [String: [BasePart]] = [:]
    for object in try await provider.listAll(prefix: VaultPath.replicasPrefix) {
      guard case .basePart(let replica, let upTo, let tag, _, _) = VaultPath.classify(object.key) else { continue }
      let part = try BaseCodec.openPart(try await provider.get(object.key), at: object.key, vault: SyncFixture.vault) { ring.key($0) }
      parts["\(replica)/\(upTo)/\(tag)", default: []].append(part)
    }
    return try parts.values.flatMap { try BaseCodec.assemble($0) { ring.key($0) }.lines }.map { try ChangeRecord(json: CanonicalJSON.decode($0)) }
  }

  /// The merge of every segment and base in storage, which by law 3 is everything any replica wrote.
  static func reference(in provider: any StorageProvider, ring: KeyRing, registry: SchemaRegistry = SyncFixture.registry, also extra: [ChangeRecord] = []) async throws
    -> String
  {
    var state = VaultState()
    for record in try await records(in: provider, ring: ring) + baseRecords(in: provider, ring: ring) + extra { state.apply(record, registry: registry) }
    return state.retained(registry: registry).digest
  }

  /// What compaction will do: record a base of the replica's own writes, put its parts, then delete every segment it covers.
  @discardableResult
  static func compact(_ harness: SyncHarness, in provider: InMemoryStorageProvider) async throws -> [SealedFile] {
    let replica = harness.store.replica
    let head = try await harness.store.read { try ReplicaHistory.head(of: replica, in: $0.database) }
    let parts = try await base(of: harness, through: head)
    try await put(parts, in: provider)
    guard case .basePart(_, let upTo, _, _, _) = VaultPath.classify(try #require(parts.first).key) else { throw SyncFixtureFailure("not a base part") }
    var covered: [(key: ObjectKey, point: StreamPoint)] = []
    for object in try await provider.listAll(prefix: VaultPath.segmentPrefix(replica)) {
      guard case .segment(_, _, let last, let tag) = VaultPath.classify(object.key), last <= upTo else { continue }
      covered.append((object.key, StreamPoint(last: last, tag: tag)))
    }
    try await provider.delete(covered.map(\.key))
    let deleted = covered
    try await harness.store.write { transaction in
      for file in deleted { try ReplicaHistory.markDeleted(file.point, isBase: false, replica: replica, at: 1, in: transaction.database) }
    }
    return parts
  }

  static func put(_ files: [SealedFile], in provider: any StorageProvider) async throws {
    for file in files { _ = try await provider.put(file.key, data: file.data, condition: .overwrite) }
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
