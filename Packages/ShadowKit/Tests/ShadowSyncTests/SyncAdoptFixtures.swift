import Foundation
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

/// Runs `body` the first time the returned closure is called and never again.
func once(_ body: @escaping @Sendable () async throws -> Void) -> @Sendable () async throws -> Void {
  let fired = Mutex(false)
  return {
    let first = fired.withLock { fired in
      defer { fired = true }
      return !fired
    }
    guard first else { return }
    try await body()
  }
}

extension SyncAdoptionOutcome {
  static func adopted(_ replicas: [ReplicaID]) -> SyncAdoptionOutcome {
    .progressed(adopted: replicas, waiting: [])
  }

  static func inProgress(_ replicas: [ReplicaID]) -> SyncAdoptionOutcome {
    .progressed(adopted: [], waiting: replicas)
  }
}

enum SyncAdoptCheckpoint: Sendable, Equatable {
  case adoption(SyncAdoptionStep)
  case compaction(SyncCompactionStep)
}

/// Counts the adoption and compaction checkpoints an engine reaches as one sequence, can crash at the n-th one, and can run an action at each.
final class SyncAdoptProbe: Sendable {
  private let reached = Mutex<[SyncAdoptCheckpoint]>([])
  private let crashIndex: Int?
  private let action: (@Sendable (SyncAdoptCheckpoint) async throws -> Void)?

  init(crashAt index: Int? = nil, action: (@Sendable (SyncAdoptCheckpoint) async throws -> Void)? = nil) {
    crashIndex = index
    self.action = action
  }

  var steps: [SyncAdoptCheckpoint] { reached.withLock { $0 } }

  var adoption: @Sendable (SyncAdoptionStep) async throws(SyncError) -> Void {
    { step async throws(SyncError) in try await self.reach(.adoption(step)) }
  }

  var compaction: @Sendable (SyncCompactionStep) async throws(SyncError) -> Void {
    { step async throws(SyncError) in try await self.reach(.compaction(step)) }
  }

  private func reach(_ step: SyncAdoptCheckpoint) async throws(SyncError) {
    let index = reached.withLock { steps in
      steps.append(step)
      return steps.count - 1
    }
    if let action {
      do {
        try await action(step)
      } catch {
        throw .corruptState("the seam failed: \(error)")
      }
    }
    if index == crashIndex { throw SyncFixture.crash }
  }
}

/// Keeps every segment ever put, so a reference holds every change any replica uploaded, whether or not its file was deleted since.
final class SyncPutLog: StorageProvider {
  private let inner: any StorageProvider
  private let segments = Mutex<[ObjectKey: Data]>([:])

  init(wrapping inner: any StorageProvider = InMemoryStorageProvider()) {
    self.inner = inner
  }

  var capabilities: StorageCapabilities { inner.capabilities }

  var putSegments: [ObjectKey: Data] { segments.withLock { $0 } }

  func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await inner.list(prefix: prefix, after: cursor)
  }

  func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    try await inner.get(key)
  }

  func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    let receipt = try await inner.put(key, data: data, condition: condition)
    if case .segment = VaultPath.classify(key) { segments.withLock { $0[key] = data } }
    return receipt
  }

  func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

/// Calls `audit` with every batch of keys before it is deleted, so a test can check the deleting database's fold rows at that moment.
final class SyncAuditingProvider: StorageProvider {
  private let inner: any StorageProvider
  private let audit: @Sendable ([ObjectKey]) async -> Void

  init(wrapping inner: any StorageProvider, audit: @escaping @Sendable ([ObjectKey]) async -> Void) {
    self.inner = inner
    self.audit = audit
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
    await audit(keys)
    try await inner.delete(keys)
  }

  func changeNotices() -> AsyncStream<Void> {
    inner.changeNotices()
  }
}

enum SyncAdoptCheck {
  /// A segment no ring key opens holds nothing any replica can apply, so it adds nothing to the reference.
  static func uploadedLines(_ log: SyncPutLog, ring: KeyRing) throws -> Set<Data> {
    _ = try ring.refresh()
    var lines: Set<Data> = []
    for (key, data) in log.putSegments {
      guard let file = try? SegmentCodec.open(data, at: key, vault: SyncFixture.vault, keys: { ring.key($0) }) else { continue }
      lines.formUnion(file.lines)
    }
    return lines
  }

  /// The merge of every segment ever put and `extra`: by law 3 everything any replica wrote, once nothing is pending.
  static func reference(_ log: SyncPutLog, ring: KeyRing, registry: SchemaRegistry = SyncFixture.registry, extra: some Sequence<Data> = [Data]()) throws -> String {
    var state = VaultState()
    for line in try uploadedLines(log, ring: ring).union(extra) {
      if let json = try? CanonicalJSON.decode(line, mode: .canonical), let record = try? ChangeRecord(json: json) {
        state.apply(record, registry: registry)
      } else {
        state.keepOpaque(line)
      }
    }
    return state.retained(registry: registry).digest
  }

  static func stored(under replica: ReplicaID, in storage: any StorageProvider) async throws -> [ObjectKey] {
    try await storage.listAll(prefix: VaultPath.replicaPrefix(replica)).map(\.key)
  }

  static func rows(_ harness: SyncHarness) async throws -> [ReplicaID: SyncAdoptionRow] {
    let replica = harness.store.replica
    return try await harness.store.read { try SyncAdoptionTable.rows(of: replica, in: $0.database) }
  }

  static func folds(_ harness: SyncHarness) async throws -> [ReplicaID: [ObjectKey: SyncFoldRow]] {
    let replica = harness.store.replica
    return try await harness.store.read { try SyncAdoptionTable.folds(of: replica, in: $0.database) }
  }

  static func facts(_ harness: SyncHarness) async throws -> [SyncAdoptionFact] {
    try await harness.lifecycle.directory().adoptions
  }

  /// The lines of every complete base under `replica`'s prefix.
  static func baseLines(of replica: ReplicaID, in storage: any StorageProvider, ring: KeyRing) async throws -> [Data] {
    var parts: [StreamPoint: [BasePart]] = [:]
    for object in try await storage.listAll(prefix: VaultPath.basePrefix(replica)) {
      guard case .basePart(_, let upTo, let tag, _, _) = VaultPath.classify(object.key) else { continue }
      parts[StreamPoint(last: upTo, tag: tag), default: []].append(
        try BaseCodec.openPart(try await storage.get(object.key), at: object.key, vault: SyncFixture.vault) { ring.key($0) })
    }
    return parts.values.flatMap { (try? BaseCodec.assemble($0) { ring.key($0) }.lines) ?? [] }
  }

  /// Runs adoption until a call finds nothing to adopt; returns every outcome on the way.
  @discardableResult
  static func finish(_ harness: SyncHarness, calls: Int = 8) async throws -> [SyncAdoptionOutcome] {
    var outcomes: [SyncAdoptionOutcome] = []
    for _ in 0..<calls {
      let outcome = try await harness.engine.adopt()
      outcomes.append(outcome)
      if outcome == .nothingToAdopt { return outcomes }
    }
    throw SyncFixtureFailure("adoption did not come to rest: \(outcomes)")
  }
}

let adoptSettings = SyncConfiguration(
  maximumSegmentLines: 2, compactionAge: .zero, compactionBytes: .max, compactionFiles: .max, compactionInterval: .zero, basePartBytes: 1_000)

/// A retired replica with a multi-part base and later segments, an adopter that names itself its successor, a bystander and a reader that applied only its first files.
struct SyncAdoptScenario {
  let world: SyncCompactWorld
  let log: SyncPutLog
  let settings: SyncConfiguration
  let retiredStore: VaultStore
  let adopterStore: VaultStore
  let retired: SyncHarness
  var adopter: SyncHarness
  let bystander: SyncHarness
  let half: SyncHarness
  let adopterProvider: SyncCompactProvider

  var retiredID: ReplicaID { retiredStore.replica }
  var adopterID: ReplicaID { adopterStore.replica }

  static func title(_ prefix: String) -> (Int) -> String {
    { "\(prefix) title \($0) \(String(repeating: "~", count: 120))" }
  }

  static func make(settings: SyncConfiguration = adoptSettings, retire: Bool = true) async throws -> SyncAdoptScenario {
    let log = SyncPutLog()
    let world = SyncCompactWorld(storage: log)
    let retiredStore = try world.openStore()
    let retired = try await world.started(world.harness("retired", store: retiredStore, configuration: settings), createsKey: true)
    try await retired.writeNotes(3, prefix: "r1-", title: title("r1"))
    _ = try await retired.uploaded()
    let half = try await world.started(world.harness("half", store: try world.openStore(), configuration: settings))
    try await SyncCompactCheck.drain(half)
    try await retired.writeNotes(4, prefix: "r2-", title: title("r2"))
    _ = try await retired.uploaded()
    guard case .compacted = try await retired.engine.compact(force: true) else { throw SyncFixtureFailure("the retired replica did not compact") }
    try await retired.writeNotes(3, prefix: "r3-", title: title("r3"))
    _ = try await retired.uploaded()
    let adopterStore = try world.openStore()
    let adopterProvider = SyncCompactProvider(wrapping: log)
    let adopter = try await world.started(world.harness("adopter", store: adopterStore, provider: adopterProvider, configuration: settings))
    let bystander = try await world.started(world.harness("bystander", store: try world.openStore(), configuration: settings))
    try await adopter.writeNotes(2, prefix: "a-")
    try await bystander.writeNotes(2, prefix: "b-")
    for peer in [adopter, bystander] { _ = try await peer.engine.sync() }
    for peer in [adopter, bystander] { _ = try await peer.engine.sync() }
    let scenario = SyncAdoptScenario(
      world: world, log: log, settings: settings, retiredStore: retiredStore, adopterStore: adopterStore, retired: retired, adopter: adopter, bystander: bystander,
      half: half, adopterProvider: adopterProvider)
    if retire { try await scenario.retireAndWait() }
    return scenario
  }

  func retireAndWait() async throws {
    try await adopter.lifecycle.retire(retiredID, successor: adopterID)
    _ = try await adopter.engine.sync()
    world.advance(days: 31)
    _ = try await bystander.engine.sync()
  }

  func engine(probe: SyncAdoptProbe = SyncAdoptProbe(), provider: (any StorageProvider)? = nil) async throws -> SyncHarness {
    let harness = world.harness(
      "adopter", store: adopterStore, provider: provider ?? adopterProvider, configuration: settings, compactionCheckpoint: probe.compaction,
      adoptionCheckpoint: probe.adoption)
    #expect(try await harness.engine.start() == .alreadyRunning)
    return harness
  }

  func reference(also extra: some Sequence<Data> = [Data]()) async throws -> String {
    try SyncAdoptCheck.reference(log, ring: retired.ring, extra: Array(extra))
  }

  /// Drains `reader` and checks it holds every change ever uploaded and its own.
  func expectConverges(_ reader: SyncHarness, _ name: String) async throws {
    try await SyncCompactCheck.drain(reader)
    let expected = try await reference(also: try await reader.pendingLines())
    #expect(try await reader.digest() == expected, "reader \(name)")
  }

  func freshReader(_ name: String) async throws -> SyncHarness {
    try await world.started(world.harness(name, store: try world.openStore(), provider: log, configuration: settings))
  }

  /// Nothing of the retired replica is left in storage, and the adopter's base holds a record of every note it wrote.
  func expectAdopted(by harness: SyncHarness) async throws {
    #expect(try await SyncAdoptCheck.stored(under: retiredID, in: log).isEmpty)
    #expect(harness.store.replica == adopterID)
    #expect(try await SyncAdoptCheck.folds(harness).isEmpty)
    let lines = try await SyncAdoptCheck.baseLines(of: adopterID, in: log, ring: harness.ring)
    let keys = Set(try lines.compactMap { try? ChangeRecord(json: CanonicalJSON.decode($0)) }.filter { $0.clock.replica == retiredID }.map(\.key.rawValue))
    for prefix in ["r1-", "r2-", "r3-"] { #expect(keys.contains("\(prefix)0"), "the adopter's base lacks \(prefix)0") }
  }
}
