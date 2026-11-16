import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

/// One peer's view of shared storage: it records gets, puts and deletes, can hide keys from listings, and can impose a smaller object limit.
final class SyncCompactProvider: StorageProvider {
  private struct State {
    var gets: [ObjectKey: Int] = [:]
    var puts: [ObjectKey] = []
    var deleted: [ObjectKey] = []
    var hidden: [String] = []
    var late: [ObjectKey: Int] = [:]
    var lingering: [String] = []
  }

  private let inner: any StorageProvider
  private let maxObjectBytes: Int?
  private let state = Mutex(State())

  init(wrapping inner: any StorageProvider, maxObjectBytes: Int? = nil) {
    self.inner = inner
    self.maxObjectBytes = maxObjectBytes
  }

  var capabilities: StorageCapabilities {
    let base = inner.capabilities
    return StorageCapabilities(
      pushesChangeNotices: base.pushesChangeNotices, supportsPutIfAbsent: base.supportsPutIfAbsent, hasChangeFeed: base.hasChangeFeed,
      reportsServerTime: base.reportsServerTime, maxObjectBytes: maxObjectBytes ?? base.maxObjectBytes, classPolicy: base.classPolicy)
  }

  var deleted: [ObjectKey] { state.withLock { $0.deleted } }
  var puts: [ObjectKey] { state.withLock { $0.puts } }

  func gets(of key: ObjectKey) -> Int {
    state.withLock { $0.gets[key] ?? 0 }
  }

  func hide(_ prefix: String) {
    state.withLock { $0.hidden.append(prefix) }
  }

  func reveal() {
    state.withLock { $0.hidden = [] }
  }

  /// Records deletes of keys under `prefix` but leaves the objects in storage, as a delete that takes effect late.
  func linger(_ prefix: String) {
    state.withLock { $0.lingering.append(prefix) }
  }

  /// Leaves `key` out of the next `listings` listings that would show it, the way a listing lags behind a put.
  func delay(_ key: ObjectKey, listings: Int) {
    state.withLock { $0.late[key] = listings }
  }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let page = try await inner.list(prefix: prefix, after: cursor)
    let (hidden, late) = state.withLock { state in
      let late = Set(state.late.filter { $0.value > 0 && $0.key.hasPrefix(prefix) }.keys)
      if cursor == nil { for key in late { state.late[key, default: 0] -= 1 } }
      return (state.hidden, late)
    }
    return ListPage(objects: page.objects.filter { object in !late.contains(object.key) && !hidden.contains { object.key.hasPrefix($0) } }, next: page.next)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    state.withLock { $0.gets[key, default: 0] += 1 }
    return try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    if let maxObjectBytes, data.count > maxObjectBytes { throw .tooLarge(key, limit: maxObjectBytes) }
    state.withLock { $0.puts.append(key) }
    return try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    let effective = state.withLock { state in
      state.deleted += keys
      return keys.filter { key in !state.lingering.contains { key.hasPrefix($0) } }
    }
    try await inner.delete(effective)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

/// Counts the compaction checkpoints an engine reaches, can crash at the n-th one, and can run an action at the first time it reaches a step.
final class SyncCompactionProbe: Sendable {
  private let reached = Mutex<[SyncCompactionStep]>([])
  private let crashIndex: Int?
  private let actionStep: SyncCompactionStep
  private let action: (@Sendable () async throws -> Void)?

  init(crashAt index: Int? = nil, at actionStep: SyncCompactionStep = .settled, action: (@Sendable () async throws -> Void)? = nil) {
    crashIndex = index
    self.actionStep = actionStep
    self.action = action
  }

  var steps: [SyncCompactionStep] { reached.withLock { $0 } }

  var checkpoint: @Sendable (SyncCompactionStep) async throws(SyncError) -> Void {
    { step async throws(SyncError) in
      let index = self.reached.withLock { steps in
        steps.append(step)
        return steps.count - 1
      }
      let first = self.reached.withLock { steps in steps.filter { $0 == step }.count == 1 }
      if step == self.actionStep, first, let action = self.action {
        do {
          try await action()
        } catch {
          throw .corruptState("the seam failed: \(error)")
        }
      }
      if index == self.crashIndex { throw SyncFixture.crash }
    }
  }
}

enum SyncDays {
  static let day: TimeInterval = 24 * 60 * 60

  static func duration(_ days: Int) -> Duration {
    .seconds(days * 24 * 60 * 60)
  }
}

/// Peers over one storage and keychain, each with its own provider view, clock-driven by one settable clock.
final class SyncCompactWorld: Sendable {
  let storage: any StorageProvider
  let keychain = InMemoryKeychain()
  let clock = SyncSettableClock(SyncFixture.start)

  init(storage: any StorageProvider = InMemoryStorageProvider()) {
    self.storage = storage
  }

  func advance(days: Double) {
    clock.set(clock.now.addingTimeInterval(days * SyncDays.day))
  }

  func openStore(_ location: StoreLocation = .inMemory, registry: SchemaRegistry = SyncFixture.registry) throws -> VaultStore {
    let clock = clock
    let trusted = TrustedClock(wallClock: { clock.now }, monotonic: SyncFixedMonotonic())
    return try SyncFixture.open(location, registry: registry, wallClock: SyncEngine.wallClock(preferring: trusted) { clock.now })
  }

  func harness(
    _ device: String, store: VaultStore, provider: (any StorageProvider)? = nil, configuration: SyncConfiguration, crashAt step: SyncUploadStep? = nil,
    probe: SyncCompactionProbe = SyncCompactionProbe(),
    compactionCheckpoint: (@Sendable (SyncCompactionStep) async throws(SyncError) -> Void)? = nil,
    adoptionCheckpoint: @escaping @Sendable (SyncAdoptionStep) async throws(SyncError) -> Void = { _ async throws(SyncError) in }
  ) -> SyncHarness {
    let clock = clock
    let trusted = TrustedClock(wallClock: { clock.now }, monotonic: SyncFixedMonotonic())
    return SyncHarness(
      store: store, provider: provider ?? SyncCompactProvider(wrapping: storage), keychain: keychain, device: device, configuration: configuration, trustedClock: trusted,
      wallClock: { clock.now }, crashAt: step, compactionCheckpoint: compactionCheckpoint ?? probe.checkpoint, adoptionCheckpoint: adoptionCheckpoint)
  }

  /// The first peer creates the vault key; every later one receives it through the keychain.
  @discardableResult
  func started(_ harness: SyncHarness, createsKey: Bool = false) async throws -> SyncHarness {
    if createsKey { _ = try harness.ring.createKey() }
    keychain.deliver()
    _ = try await harness.engine.start()
    return harness
  }
}

struct SyncStoredBase: Equatable {
  let point: StreamPoint
  let parts: Int
  let present: Set<Int>

  var isComplete: Bool { present.count == parts }
}

/// What storage holds under one replica's prefix, read with a perfect view.
struct SyncStoredFiles {
  let segments: Set<StreamPoint>
  let bases: [StreamPoint: SyncStoredBase]
  let partSizes: [Int]

  static func read(_ replica: ReplicaID, in storage: any StorageProvider) async throws -> SyncStoredFiles {
    var segments: Set<StreamPoint> = []
    var bases: [StreamPoint: SyncStoredBase] = [:]
    var sizes: [Int] = []
    for object in try await storage.listAll(prefix: VaultPath.replicaPrefix(replica)) {
      switch VaultPath.classify(object.key) {
      case .segment(_, _, let last, let tag):
        segments.insert(StreamPoint(last: last, tag: tag))
      case .basePart(_, let upTo, let tag, let part, let parts):
        let point = StreamPoint(last: upTo, tag: tag)
        let existing = bases[point] ?? SyncStoredBase(point: point, parts: parts, present: [])
        bases[point] = SyncStoredBase(point: point, parts: parts, present: existing.present.union([part]))
        sizes.append(object.size)
      default:
        continue
      }
    }
    return SyncStoredFiles(segments: segments, bases: bases, partSizes: sizes)
  }
}

enum SyncCompactCheck {
  static func entries(_ harness: SyncHarness, of replica: ReplicaID? = nil) async throws -> [SyncUploadEntry] {
    let replica = replica ?? harness.store.replica
    return try await harness.store.read { try ReplicaHistory.entries(of: replica, in: $0.database) }
  }

  static func row(_ harness: SyncHarness) async throws -> SyncCompactionRow? {
    try await harness.store.read { try SyncCompactionTable.load($0.database) }
  }

  /// Every key a peer asked storage to delete names a segment or base that peer's upload history recorded.
  static func ownDeletes(_ deleted: [ObjectKey], by store: VaultStore) async throws -> [ObjectKey] {
    var strangers: [ObjectKey] = []
    for key in deleted {
      let known: Bool
      switch VaultPath.classify(key) {
      case .segment(let replica, let first, let last, let tag):
        let entries = try await store.read { try ReplicaHistory.entries(of: replica, in: $0.database) }
        known = entries.contains { !$0.isBase && $0.point == StreamPoint(last: last, tag: tag) && $0.first == first }
      case .basePart(let replica, let upTo, let tag, _, _):
        let entries = try await store.read { try ReplicaHistory.entries(of: replica, in: $0.database) }
        known = entries.contains { $0.isBase && $0.point == StreamPoint(last: upTo, tag: tag) }
      default:
        known = false
      }
      if !known { strangers.append(key) }
    }
    return strangers
  }

  static func reference(_ lines: some Sequence<Data>, registry: SchemaRegistry = SyncFixture.registry) throws -> String {
    var state = VaultState()
    for line in Set(lines) { state.apply(try ChangeRecord(json: CanonicalJSON.decode(line)), registry: registry) }
    return state.retained(registry: registry).digest
  }

  /// Downloads until a call applies nothing; returns the files applied along the way.
  @discardableResult
  static func drain(_ harness: SyncHarness, calls: Int = 12) async throws -> [SyncFileID] {
    var applied: [SyncFileID] = []
    for _ in 0..<calls {
      let outcome = try await harness.engine.download()
      if outcome.applied.isEmpty { return applied }
      applied += outcome.applied
    }
    throw SyncFixtureFailure("downloads kept applying files")
  }
}
