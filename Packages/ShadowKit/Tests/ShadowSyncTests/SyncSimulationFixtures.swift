import Foundation
import GRDB
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

enum SyncSimulationBudget {
  /// Multiplies every seeded case count, for a nightly run: `SHADOW_SYNC_SIMULATION_SCALE=20 swift test --filter SyncSimulation`.
  static let scale = max(1, Int(ProcessInfo.processInfo.environment["SHADOW_SYNC_SIMULATION_SCALE"] ?? "") ?? 1)

  /// Runs one case by the seed a failure printed: `SHADOW_SYNC_SIMULATION_REPLAY=0x… swift test --filter shouldReplaySeed`.
  /// Ring keys and record ids are not seeded, so a failure that depends on how forked files sort may not replay exactly.
  static let replay = ProcessInfo.processInfo.environment["SHADOW_SYNC_SIMULATION_REPLAY"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }

  static func cases(_ count: Int) -> Int {
    count * scale
  }
}

let syncSimSettings = SyncConfiguration(
  maximumSegmentLines: 3, compactionAge: .zero, compactionBytes: .max, compactionFiles: 6, compactionInterval: .zero, basePartBytes: 1_500,
  adoptionDelay: SyncDays.duration(2), adoptionAbandonDelay: SyncDays.duration(4))

/// Elapsed true time, so a trusted clock's estimate moves with the world between server samples.
struct SyncSimMonotonic: MonotonicTimeSource {
  let clock: SyncSettableClock

  func nanoseconds() -> UInt64 {
    UInt64(max(0, clock.now.timeIntervalSince(SyncFixture.start)) * 1_000_000_000)
  }
}

/// Replica ids from a seed, in the order they are minted, so a seed replays the same ids and the same lowest active replica.
final class SyncSimMinter: Sendable {
  private let state: Mutex<(generator: SeededGenerator, minted: UInt64)>

  init(seed: UInt64) {
    state = Mutex((SeededGenerator(seed: seed), 0))
  }

  var next: @Sendable () -> ReplicaID {
    { self.mint() }
  }

  private func mint() -> ReplicaID {
    let (millis, high, low) = state.withLock { state in
      state.minted += 1
      return (UInt64(SyncFixture.start.timeIntervalSince1970 * 1_000) + state.minted, state.generator.next(), state.generator.next())
    }
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0..<6 { bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index))) }
    for index in 6..<8 { bytes[index] = UInt8(truncatingIfNeeded: high >> (8 * index)) }
    for index in 8..<16 { bytes[index] = UInt8(truncatingIfNeeded: low >> (8 * (index - 8))) }
    bytes[6] = 0x70 | (bytes[6] & 0x0F)
    bytes[8] = 0x80 | (bytes[8] & 0x3F)
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14],
        bytes[15]
      ))
    return ReplicaID(uuid)
  }
}

extension SyncHarness {
  /// The engine as an app builds it, with the store's own public clock floor, replica ids from `minter`, and a crash where `crash` says.
  init(
    simulating store: VaultStore, provider: any StorageProvider, keychain: InMemoryKeychain, device name: String, configuration: SyncConfiguration,
    trustedClock: TrustedClock, wallClock: @escaping @Sendable () -> Date, minter: SyncSimMinter, crash: SyncSimCrash? = nil
  ) {
    self.store = store
    self.provider = provider
    self.keychain = keychain
    self.trustedClock = trustedClock
    let device = keychain.device(name)
    ring = KeyRing(vault: SyncFixture.vault, store: device.store(service: "keys", scope: .synced))
    lifecycle = ReplicaLifecycle(
      store: store, vault: SyncFixture.vault, marker: DeviceMarker(store: device.store(service: "marker", scope: .device)), device: ReplicaFixture.phone,
      wallClock: wallClock, makeReplicaID: minter.next)
    var upload: @Sendable (SyncUploadStep) async throws(SyncError) -> Void = { _ async throws(SyncError) in }
    var probe = SyncAdoptProbe()
    var compaction: (@Sendable (SyncCompactionStep) async throws(SyncError) -> Void)?
    var adoption: (@Sendable (SyncAdoptionStep) async throws(SyncError) -> Void)?
    switch crash {
    case .upload(let target): upload = { step async throws(SyncError) in if step == target { throw SyncFixture.crash } }
    case .checkpoint(let index): probe = SyncAdoptProbe(crashAt: index)
    case .every(.compaction(let target)): compaction = { step async throws(SyncError) in if step == target { throw SyncFixture.crash } }
    case .every(.adoption(let target)): adoption = { step async throws(SyncError) in if step == target { throw SyncFixture.crash } }
    case nil: break
    }
    let floor: @Sendable () async throws(SyncError) -> HLCTimestamp? = { () async throws(SyncError) in
      do throws(StoreError) {
        return try await store.publicClockFloor()
      } catch {
        throw SyncError(converting: error)
      }
    }
    engine = SyncEngine(
      store: store, provider: provider, vault: SyncFixture.vault, ring: ring, lifecycle: lifecycle, trustedClock: trustedClock, configuration: configuration,
      wallClock: wallClock, publicFloor: floor, checkpoint: upload, compactionCheckpoint: compaction ?? probe.compaction, adoptionCheckpoint: adoption ?? probe.adoption)
  }
}

final class SyncSimOffset: Sendable {
  private let seconds: Mutex<TimeInterval>

  init(_ seconds: TimeInterval = 0) {
    self.seconds = Mutex(seconds)
  }

  var value: TimeInterval { seconds.withLock { $0 } }

  func set(_ value: TimeInterval) {
    seconds.withLock { $0 = value }
  }
}

final class SyncSimStoreBox: Sendable {
  private let current = Mutex<VaultStore?>(nil)

  var store: VaultStore? { current.withLock { $0 } }

  func set(_ store: VaultStore) {
    current.withLock { $0 = store }
  }
}

/// Checks each key a device deletes against the K17a and K17b delete rules, with a perfect view of storage at that moment.
final class SyncSimAudit: Sendable {
  private let truth: any StorageProvider
  private let abandonDelay: Duration
  private let found = Mutex<[String]>([])
  private let counts = Mutex<(own: Int, foreign: Int)>((0, 0))

  init(truth: any StorageProvider, abandonDelay: Duration) {
    self.truth = truth
    self.abandonDelay = abandonDelay
  }

  var violations: [String] { found.withLock { $0 } }
  var ownDeletes: Int { counts.withLock { $0.own } }
  var foreignDeletes: Int { counts.withLock { $0.foreign } }

  func check(_ keys: [ObjectKey], by store: VaultStore, device: String) async {
    for key in keys {
      do {
        if let violation = try await violation(key, by: store) { found.withLock { $0.append("\(device) as \(store.replica) deleted \(key): \(violation)") } }
      } catch {
        found.withLock { $0.append("\(device) deleted \(key): the audit failed: \(error)") }
      }
    }
  }

  private func violation(_ key: ObjectKey, by store: VaultStore) async throws -> String? {
    let deleter = store.replica
    switch VaultPath.classify(key) {
    case .manifest(let owner):
      guard owner != deleter, try await isRetired(owner, in: store) else { return "a manifest of a replica that is not retired" }
      counts.withLock { $0.foreign += 1 }
      return nil
    case .segment(let owner, let first, let last, let tag):
      if try await folded(of: owner, by: deleter, in: store).contains(key) {
        if let violation = try await foreignViolation(owner, by: deleter, in: store) { return violation }
        let facts = try await store.read { try ReplicaDirectory.adoptions(in: $0) }.filter { $0.adopted == owner && $0.adopter == deleter }
        guard facts.contains(where: { $0.through >= last }) else { return "a folded segment beyond the head every published fact covers" }
        counts.withLock { $0.foreign += 1 }
        return nil
      }
      guard owner == deleter else { return "another replica's segment that was never folded" }
      let entries = try await store.read { try ReplicaHistory.entries(of: owner, in: $0.database) }
      guard entries.contains(where: { !$0.isBase && $0.first == first && $0.point == StreamPoint(last: last, tag: tag) }) else { return "a segment it never uploaded" }
      let covering = Set(entries.filter { $0.isCompleteBase && $0.point.last >= last }.map(\.point))
      guard try await !covering.isDisjoint(with: completeBases(of: owner)) else { return "no completed base of its own in storage covers it" }
      counts.withLock { $0.own += 1 }
      return nil
    case .basePart(let owner, let upTo, let tag, _, let parts):
      let folds = try await folded(of: owner, by: deleter, in: store)
      if folds.contains(key) {
        if let violation = try await foreignViolation(owner, by: deleter, in: store) { return violation }
        let base = SyncBaseName(upTo: upTo, tag: tag, parts: parts)
        let abandoned = try await isAbandoned(base, of: owner, by: deleter, in: store)
        guard folds.isSuperset(of: base.keys(of: owner)) || abandoned else {
          return "a folded part of a base whose other parts were neither all folded nor given up"
        }
        counts.withLock { $0.foreign += 1 }
        return nil
      }
      guard owner == deleter else { return "another replica's base part that was never folded" }
      let point = StreamPoint(last: upTo, tag: tag)
      let entries = try await store.read { try ReplicaHistory.entries(of: owner, in: $0.database) }
      guard entries.contains(where: { $0.isBase && $0.point == point }) else { return "a base it never announced" }
      let superseding = Set(entries.filter { $0.isCompleteBase && $0.point != point && $0.point.last >= upTo }.map(\.point))
      guard try await !superseding.isDisjoint(with: completeBases(of: owner)) else { return "no other completed base of its own in storage supersedes it" }
      counts.withLock { $0.own += 1 }
      return nil
    default:
      return "not a replica file"
    }
  }

  private func foreignViolation(_ owner: ReplicaID, by deleter: ReplicaID, in store: VaultStore) async throws -> String? {
    guard owner != deleter, try await isRetired(owner, in: store) else { return "a folded file of a replica that is not retired" }
    let facts = try await store.read { try ReplicaDirectory.adoptions(in: $0) }.filter { $0.adopted == owner && $0.adopter == deleter }
    let bases = try await completeBases(of: deleter)
    guard facts.contains(where: { fact in bases.contains { $0.last >= fact.at } }) else { return "no complete base of the adopter reaches a published fact" }
    return nil
  }

  private func folded(of owner: ReplicaID, by deleter: ReplicaID, in store: VaultStore) async throws -> Set<ObjectKey> {
    try await store.read { try SyncAdoptionTable.foldedKeys(of: owner, by: deleter, in: $0.database) }
  }

  private func isAbandoned(_ base: SyncBaseName, of owner: ReplicaID, by deleter: ReplicaID, in store: VaultStore) async throws -> Bool {
    let sql = "SELECT seen FROM sync_adoption_gap WHERE adopter = ? AND adopted = ? AND up_to = ? AND tag = ? AND parts = ?"
    let arguments: StatementArguments = [deleter.description, owner.description, base.upTo, base.tag.description, base.parts]
    guard let seen = try await store.read({ try Int64.fetchOne($0.database, sql: sql, arguments: arguments) }) else { return false }
    let now = Int64(store.wallClock().timeIntervalSince1970 * 1_000)
    return now - seen >= abandonDelay.components.seconds * 1_000
  }

  private func isRetired(_ replica: ReplicaID, in store: VaultStore) async throws -> Bool {
    try await store.read { ReplicaDirectory.isRetired(try $0.state(of: SyncKernelSchema.replicaRef(replica))) }
  }

  private func completeBases(of replica: ReplicaID) async throws -> Set<StreamPoint> {
    Set(try await SyncStoredFiles.read(replica, in: truth).bases.values.filter(\.isComplete).map(\.point))
  }
}

final class SyncSimAuditingProvider: StorageProvider {
  private let inner: any StorageProvider
  private let audit: SyncSimAudit
  private let box: SyncSimStoreBox
  private let device: String

  init(wrapping inner: any StorageProvider, audit: SyncSimAudit, box: SyncSimStoreBox, device: String) {
    self.inner = inner
    self.audit = audit
    self.box = box
    self.device = device
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    try await inner.put(key, data: data, condition: condition)
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    if let store = box.store { await audit.check(keys, by: store, device: device) }
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

/// Names a replica once it exists, so a fault set up before can single out that replica's base parts.
final class SyncSimTarget: Sendable {
  private let replica = Mutex<ReplicaID?>(nil)

  func set(_ value: ReplicaID) {
    replica.withLock { $0 = value }
  }

  func isBasePart(_ key: ObjectKey) -> Bool {
    guard case .basePart(let owner, _, _, _, _) = VaultPath.classify(key) else { return false }
    return replica.withLock { $0 } == owner
  }
}

struct SyncSimFaults {
  var plan: FaultPlan?
  var lag: Double = 0
  var lagListings: ClosedRange<Int> = 1...4
  var lagged: @Sendable (ObjectKey) -> Bool = { _ in true }
  var seed: UInt64 = 0

  static let none = SyncSimFaults()

  static func isReplicaFile(_ key: ObjectKey) -> Bool {
    switch VaultPath.classify(key) {
    case .segment, .basePart: true
    default: false
    }
  }
}

final class SyncSimDevice {
  let name: String
  let offset: SyncSimOffset
  let box: SyncSimStoreBox
  let faults: FaultInjectingStorageProvider?
  let lag: LaggingListingStorageProvider
  let view: any StorageProvider
  var registry: SchemaRegistry
  var database: URL
  var harness: SyncHarness

  init(
    name: String, offset: SyncSimOffset, box: SyncSimStoreBox, faults: FaultInjectingStorageProvider?, lag: LaggingListingStorageProvider, view: any StorageProvider,
    registry: SchemaRegistry,
    database: URL, harness: SyncHarness
  ) {
    self.name = name
    self.offset = offset
    self.box = box
    self.faults = faults
    self.lag = lag
    self.view = view
    self.registry = registry
    self.database = database
    self.harness = harness
  }

  var store: VaultStore { harness.store }
  var engine: SyncEngine { harness.engine }
  var replica: ReplicaID { harness.store.replica }

  func heal() {
    faults?.setFaultsEnabled(false)
    faults?.heal()
    lag.setEnabled(false)
    lag.heal()
  }
}

enum SyncSimCrash {
  case upload(SyncUploadStep)
  case checkpoint(Int)
  /// Every time the engine reaches this step.
  case every(SyncAdoptCheckpoint)
}

/// Devices over one local-folder vault and one keychain, on file-based stores, with a true clock that only moves forward.
/// It keeps every unique note any device wrote, and the notes a thrown-away database still held unsent, to tell a lost change from one nobody could have kept.
final class SyncSimWorld {
  let directory = ReplicaTemporaryDirectory()
  let clock: SyncSettableClock
  let keychain = InMemoryKeychain()
  let log: SyncPutLog
  let shared: any StorageProvider
  let configuration: SyncConfiguration
  let audit: SyncSimAudit
  let observer: KeyRing
  let minter: SyncSimMinter
  private(set) var devices: [SyncSimDevice] = []
  /// Devices that neither settle nor are verified until they come back.
  var offline: Set<String> = []
  private(set) var titles: [String: String] = [:]
  /// What happened, step by step, for the message of a failing seed.
  private(set) var trace: [String] = []
  private var discarded: Set<String> = []
  private var serial = 0
  private var files = 0
  private var readers = 0
  private var references: [Int: (state: VaultState, seen: Set<ObjectKey>)] = [:]

  init(seed: UInt64 = 0x5EED, serverTime: Bool = false, configuration: SyncConfiguration = syncSimSettings) throws {
    minter = SyncSimMinter(seed: seed)
    let clock = SyncSettableClock(SyncFixture.start)
    self.clock = clock
    log = SyncPutLog(wrapping: try LocalFolderProvider(root: directory.url.appending(path: "storage", directoryHint: .isDirectory)))
    shared = serverTime ? ServerTimeStorageProvider(wrapping: log) { clock.now } : log
    self.configuration = configuration
    audit = SyncSimAudit(truth: log, abandonDelay: configuration.adoptionAbandonDelay)
    observer = KeyRing(vault: SyncFixture.vault, store: keychain.device("observer").store(service: "keys", scope: .synced))
  }

  var online: [SyncSimDevice] { devices.filter { !offline.contains($0.name) } }

  func note(_ event: String) {
    trace.append(event)
  }

  func advance(days: Double) {
    clock.set(clock.now.addingTimeInterval(days * SyncDays.day))
  }

  @discardableResult
  func addDevice(_ name: String, registry: SchemaRegistry = SyncFixture.registry, offset: TimeInterval = 0, faults: SyncSimFaults = .none) async throws -> SyncSimDevice {
    try await add(name, registry: registry, offset: offset, faults: faults, database: nextDatabase(name))
  }

  private func add(_ name: String, registry: SchemaRegistry, offset: TimeInterval, faults: SyncSimFaults, database: URL) async throws -> SyncSimDevice {
    let box = SyncSimStoreBox()
    let injected = faults.plan.map { FaultInjectingStorageProvider(wrapping: shared, seed: faults.seed, plan: $0) }
    let lagging = LaggingListingStorageProvider(
      wrapping: injected ?? shared, seed: faults.seed &+ 1, probability: faults.lag, listings: faults.lagListings, eligible: faults.lagged)
    let view = SyncSimAuditingProvider(wrapping: lagging, audit: audit, box: box, device: name)
    let skew = SyncSimOffset(offset)
    let harness = try launch(name, database: database, registry: registry, offset: skew, view: view, box: box)
    let device = SyncSimDevice(name: name, offset: skew, box: box, faults: injected, lag: lagging, view: view, registry: registry, database: database, harness: harness)
    if devices.isEmpty { _ = try harness.ring.createKey() }
    keychain.deliver()
    _ = try await harness.engine.start()
    devices.append(device)
    return device
  }

  private func launch(
    _ name: String, database: URL, registry: SchemaRegistry, offset: SyncSimOffset, view: any StorageProvider, box: SyncSimStoreBox, crash: SyncSimCrash? = nil
  ) throws -> SyncHarness {
    let clock = clock
    let deviceNow: @Sendable () -> Date = { clock.now.addingTimeInterval(offset.value) }
    let trusted = TrustedClock(wallClock: deviceNow, monotonic: SyncSimMonotonic(clock: clock))
    let store = try SyncFixture.open(.file(database), registry: registry, wallClock: SyncEngine.wallClock(preferring: trusted, device: deviceNow))
    box.set(store)
    return SyncHarness(
      simulating: store, provider: view, keychain: keychain, device: name, configuration: configuration, trustedClock: trusted, wallClock: deviceNow, minter: minter,
      crash: crash)
  }

  private func nextDatabase(_ name: String) -> URL {
    files += 1
    return directory.database("\(name)-\(files)")
  }

  /// A new process on the same database file: a new store, engine and trusted clock, optionally one that crashes at a step.
  @discardableResult
  func restart(_ device: SyncSimDevice, crash: SyncSimCrash? = nil) async throws -> ReplicaBootstrap {
    let harness = try launch(device.name, database: device.database, registry: device.registry, offset: device.offset, view: device.view, box: device.box, crash: crash)
    device.harness = harness
    return try await harness.engine.start()
  }

  // MARK: Writes

  /// Writes `count` notes no other write touches, each with a title only this write uses.
  func write(_ count: Int, on device: SyncSimDevice) async throws {
    var notes: [(key: String, title: String)] = []
    for _ in 0..<count {
      serial += 1
      notes.append(("u\(serial)", "\(device.name) wrote \(serial)"))
    }
    let batch = notes
    try await device.store.write { transaction in
      for note in batch { _ = try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key(note.key)), ["title": .string(note.title)]) }
    }
    for note in batch { titles[note.key] = note.title }
  }

  /// Sets or purges one of a few notes every device writes, so concurrent writes meet; a purged note refuses later sets.
  func contest(_ index: Int, on device: SyncSimDevice, purge: Bool = false) async throws {
    serial += 1
    let ref = EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("c\(index)"))
    let title = "\(device.name) contested \(serial)"
    do {
      _ = try await device.store.write { transaction in purge ? try transaction.purge(ref) : try transaction.set(ref, ["title": .string(title)]) }
    } catch {
      guard case .entityPurged = error else { throw error }
    }
  }

  // MARK: Databases

  func snapshot(_ device: SyncSimDevice) throws -> URL {
    files += 1
    let copy = directory.database("\(device.name)-snapshot-\(files)")
    try ReplicaFixture.copyDatabase(from: device.database, to: copy)
    return copy
  }

  /// The device's database is replaced by an older copy; what it held unsent since is gone.
  @discardableResult
  func restore(_ device: SyncSimDevice, from snapshot: URL) async throws -> ReplicaBootstrap {
    let unsent = try await pendingNotes(device.store)
    let database = nextDatabase(device.name)
    try ReplicaFixture.copyDatabase(from: snapshot, to: database)
    device.database = database
    let bootstrap = try await restart(device)
    discarded.formUnion(unsent.subtracting(try await pendingNotes(device.store)))
    return bootstrap
  }

  /// A second device starts from a copy of `device`'s database while `device` keeps running.
  @discardableResult
  func clone(_ device: SyncSimDevice, as name: String, faults: SyncSimFaults = .none) async throws -> SyncSimDevice {
    let database = nextDatabase(name)
    try ReplicaFixture.copyDatabase(from: device.database, to: database)
    return try await add(name, registry: device.registry, offset: 0, faults: faults, database: database)
  }

  /// The app is deleted and installed again: the keychain survives, the database does not. Returns the replica the old database wrote as.
  func reinstall(_ device: SyncSimDevice) async throws -> ReplicaID {
    let old = device.replica
    try await discard(device)
    device.database = nextDatabase(device.name)
    try await restart(device)
    return old
  }

  func remove(_ device: SyncSimDevice) async throws {
    try await discard(device)
    devices.removeAll { $0 === device }
  }

  private func discard(_ device: SyncSimDevice) async throws {
    discarded.formUnion(try await pendingNotes(device.store))
  }

  private func pendingNotes(_ store: VaultStore) async throws -> Set<String> {
    Set(
      try await store.pendingChanges(limit: .max).compactMap { change in
        guard let record = try? ChangeRecord(json: CanonicalJSON.decode(change.line)), record.entity == SyncFixture.note else { return nil }
        return record.key.rawValue
      })
  }

  // MARK: Settling and invariants

  /// Every device syncs, compacts when due and adopts until a full round changes nothing; `waits` names the holds a settled device may keep.
  func settle(rounds: Int = 24, waits: (SyncHoldReason) -> Bool = SyncSimWorld.isIncompleteBase) async throws {
    for device in online { device.heal() }
    for _ in 0..<rounds {
      var quiet = true
      for device in online {
        let before = device.replica
        let (download, upload) = try await device.engine.sync()
        let compaction = try await device.engine.compact()
        let adoption = try await device.engine.adopt()
        if device.replica != before { note("   settle: \(device.name) moved from \(before) to \(device.replica)") }
        if adoption != .nothingToAdopt { note("   settle: \(device.name) adoption \(adoption)") }
        let waiting = download.held.values.contains { !waits($0) }
        if !download.applied.isEmpty || upload != .nothingToUpload || waiting || compaction != .notNeeded || !Self.isAtRest(adoption) { quiet = false }
      }
      if quiet { return }
    }
    var states: [String] = []
    for device in online {
      let (download, upload) = try await device.engine.sync()
      states.append("\(device.name): held \(download.held), upload \(upload), compact \(try await device.engine.compact()), adopt \(try await device.engine.adopt())")
    }
    throw SyncFixtureFailure("the devices did not settle within \(rounds) rounds: \(states)")
  }

  /// An adoption that only waits is waiting for time to pass: a base whose missing parts have not stayed unlisted for the abandon delay.
  static func isAtRest(_ adoption: SyncAdoptionOutcome) -> Bool {
    switch adoption {
    case .nothingToAdopt, .progressed(adopted: [], waiting: _): true
    case .progressed, .postponed: false
    }
  }

  static func isIncompleteBase(_ reason: SyncHoldReason) -> Bool {
    guard case .incompleteBase = reason else { return false }
    return true
  }

  func leftovers() async throws -> [ReplicaID: [ObjectKey]] {
    let live = Set(devices.map(\.replica))
    var left: [ReplicaID: [ObjectKey]] = [:]
    for object in try await log.listAll(prefix: VaultPath.replicasPrefix) {
      switch VaultPath.classify(object.key) {
      case .segment(let owner, _, _, _), .basePart(let owner, _, _, _, _), .manifest(let owner):
        if !live.contains(owner) { left[owner, default: []].append(object.key) }
      default:
        continue
      }
    }
    return left
  }

  func putLines() throws -> [Data] {
    keychain.deliver()
    _ = try observer.refresh()
    return log.putSegments.flatMap { key, data in (try? SegmentCodec.open(data, at: key, vault: SyncFixture.vault) { self.observer.key($0) }.lines) ?? [] }
  }

  /// The merge of every segment any device ever put, which by law 3 is every change that reached storage, and of `extra`.
  func reference(registry: SchemaRegistry = SyncFixture.registry, extra: [Data] = []) throws -> String {
    keychain.deliver()
    _ = try observer.refresh()
    var (state, seen) = references[registry.version] ?? (VaultState(), [])
    for (key, data) in log.putSegments where !seen.contains(key) {
      seen.insert(key)
      guard let file = try? SegmentCodec.open(data, at: key, vault: SyncFixture.vault, keys: { self.observer.key($0) }) else { continue }
      for line in file.lines { Self.merge(line, into: &state, registry: registry) }
    }
    references[registry.version] = (state, seen)
    for line in extra { Self.merge(line, into: &state, registry: registry) }
    return state.retained(registry: registry).digest
  }

  private static func merge(_ line: Data, into state: inout VaultState, registry: SchemaRegistry) {
    if let json = try? CanonicalJSON.decode(line, mode: .canonical), let record = try? ChangeRecord(json: json) {
      state.apply(record, registry: registry)
    } else {
      state.keepOpaque(line)
    }
  }

  /// The unique notes a settled device must hold: every one written, except those only a thrown-away database ever held.
  func expectedTitles() async throws -> [String: String] {
    var unsent: Set<String> = []
    for device in devices where offline.contains(device.name) { unsent.formUnion(try await pendingNotes(device.store)) }
    var uploaded: Set<String> = []
    for (key, data) in log.putSegments {
      guard let file = try? SegmentCodec.open(data, at: key, vault: SyncFixture.vault, keys: { self.observer.key($0) }) else { continue }
      for line in file.lines {
        guard let record = try? ChangeRecord(json: CanonicalJSON.decode(line)), record.entity == SyncFixture.note else { continue }
        uploaded.insert(record.key.rawValue)
      }
    }
    return titles.filter { (!discarded.contains($0.key) && !unsent.contains($0.key)) || uploaded.contains($0.key) }
  }

  /// After `settle`: every device holds every change that reached storage and every note it must, nothing is unsent, ids are live and distinct,
  /// every delete kept to the rules, and a reader that never synced converges.
  func verify(_ label: String, freshReader: Bool = true) async throws {
    let expected = try await expectedTitles()
    let devices = online
    let directory = try await devices[0].harness.lifecycle.directory()
    let active = Set(directory.replicas.filter { $0.state == .active }.map(\.replica))
    guard Set(devices.map(\.replica)).count == devices.count else { throw SyncFixtureFailure("\(label): two devices write as one replica") }
    for device in devices {
      let unsent = try await device.harness.pendingLines()
      guard unsent.isEmpty else {
        let upload = try await device.engine.upload()
        let records = unsent.compactMap { try? ChangeRecord(json: CanonicalJSON.decode($0)) }.map { "\($0.entity) \($0.key) \($0.clock)" }
        throw SyncFixtureFailure("\(label): \(device.name) still has unsent changes \(records); a further upload: \(upload); trace \(trace.suffix(12))")
      }
      guard try await device.harness.digest() == (try reference(registry: device.registry)) else {
        throw SyncFixtureFailure("\(label): \(device.name) differs from the merge of every change put")
      }
      let missing = try await missingTitles(expected, on: device)
      guard missing.isEmpty else { throw SyncFixtureFailure("\(label): \(device.name) lost notes \(missing.sorted().prefix(8))") }
      guard active.contains(device.replica) else { throw SyncFixtureFailure("\(label): \(device.name) writes as a replica the vault shows retired") }
    }
    guard audit.violations.isEmpty else { throw SyncFixtureFailure("\(label): deletes outside the rules: \(audit.violations)") }
    if freshReader { try await expectFreshReaderConverges(label) }
  }

  func missingTitles(_ expected: [String: String], on device: SyncSimDevice) async throws -> [String] {
    try await device.store.read { transaction in
      try expected.compactMap { key, title in
        guard case .record(let record)? = try transaction.state(of: EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key(key))),
          record[field: "title"]?.value == .string(title)
        else { return key }
        return nil
      }
    }
  }

  /// A device that never synced, over storage with no faults, converges to the merge of every change put; returns the downloads it took.
  @discardableResult
  func expectFreshReaderConverges(_ label: String, registry: SchemaRegistry = SyncFixture.registry, calls: Int = 12) async throws -> Int {
    try await freshReader(label, registry: registry, calls: calls).downloads
  }

  func freshReader(_ label: String, registry: SchemaRegistry = SyncFixture.registry, calls: Int = 12) async throws -> (reader: SyncHarness, downloads: Int) {
    readers += 1
    let clock = clock
    let trusted = TrustedClock(wallClock: { clock.now }, monotonic: SyncSimMonotonic(clock: clock))
    let reader = SyncHarness(
      simulating: try SyncFixture.open(registry: registry) { clock.now }, provider: log, keychain: keychain, device: "reader-\(readers)",
      configuration: SyncConfiguration(dependencyWaitCalls: 1), trustedClock: trusted, wallClock: { clock.now }, minter: minter)
    keychain.deliver()
    _ = try await reader.engine.start()
    let expected = try reference(registry: registry, extra: try await reader.pendingLines())
    for call in 1...calls {
      _ = try await reader.engine.download()
      if try await reader.digest() == expected { return (reader, call) }
    }
    throw SyncFixtureFailure("\(label): a fresh reader did not converge in \(calls) downloads")
  }
}
