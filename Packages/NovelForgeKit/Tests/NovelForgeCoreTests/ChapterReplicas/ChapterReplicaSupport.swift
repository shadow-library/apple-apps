import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import NovelForgeEval
@testable import ShadowJobs

/// A call held before it streams: reached once the pipeline sent it, and answered only once released or aborted when its step is cancelled.
final class CallHold: Sendable {
  private let state = Mutex((reached: false, released: false))

  var isReached: Bool { state.withLock { $0.reached } }

  func reach() {
    state.withLock { $0.reached = true }
  }

  func release() {
    state.withLock { $0.released = true }
  }

  func passed() async -> Bool {
    while !state.withLock({ $0.released }) {
      if Task.isCancelled { return false }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return true
  }
}

/// One device's model: the scripted replies queued for it, the next of which can be held, as a call in flight is when its device sleeps.
final class HeldModel: ModelProvider {
  let scripted = ScriptedModelProvider()
  private let hold = Mutex<CallHold?>(nil)

  var requests: Int { scripted.requests.count }

  func queue(_ calls: [[ScriptedModelProvider.Step]]) {
    for call in calls { scripted.enqueue(call) }
  }

  func holdNextCall() -> CallHold {
    let next = CallHold()
    hold.withLock { $0 = next }
    return next
  }

  func stream(_ request: ModelRequest) -> ModelStream {
    let held = hold.withLock { hold in
      defer { hold = nil }
      return hold
    }
    let inner = scripted.stream(request)
    return ModelStream { continuation throws(ModelError) in
      if let held {
        held.reach()
        guard await held.passed() else { throw .cancelled }
      }
      for try await event in inner { try continuation.yield(event) }
    }
  }

  func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    throw .invalidRequest("HeldModel validates no credential")
  }

  func models() async throws(ModelError) -> [RemoteModel] {
    []
  }
}

private struct DeviceCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

/// A replica as the app runs it: its store, its own lease clock, model and router, and its one job engine; its heartbeat never beats, so a lease lapses six
/// minutes after its last step boundary.
final class ChapterDevice: Sendable {
  let index: Int
  let store: VaultStore
  let clock = EngineClock()
  let model = HeldModel()
  let heartbeat = SleepGate()
  let rereads = SleepGate()
  private let current = Mutex<JobEngine?>(nil)

  init(index: Int, store: VaultStore) {
    self.index = index
    self.store = store
  }

  var replica: ReplicaID { store.replica }

  var lease: LeaseClock { LeaseClock(trusted: nil, device: clock.function) }

  var engine: JobEngine {
    get throws {
      if let engine = current.withLock({ $0 }) { return engine }
      return try relaunch()
    }
  }

  /// The app starting again: the engine before it gave the vault up as a process that ended does.
  @discardableResult
  func relaunch(_ faults: AttemptRunner.Faults = .none) throws -> JobEngine {
    current.withLock { $0 }?.relinquish()
    let (heartbeat, rereads, lease) = (heartbeat, rereads, lease)
    let timing = AttemptRunner.Timing(heartbeat: LeaseTerms.heartbeat) { _ in try await heartbeat.sleep() }
    let engine = try JobEngine(
      store: store, router: { [self] in router($0) }, consent: CompactionWorld.consent, clock: lease,
      runner: AttemptRunner(store: store, clock: lease, timing: timing, faults: faults), timing: JobEngine.Timing { _ in try await rereads.sleep() },
      unrestrictedAvailable: false)
    current.withLock { $0 = engine }
    return engine
  }

  func router(_ requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?) -> TaskRouter {
    guard let standard = ProviderBinding(origin: CompactionWorld.anthropic, provider: model),
      let unrestricted = ProviderBinding(origin: CompactionWorld.openRouter, provider: model)
    else { preconditionFailure("valid bindings") }
    let configuration = TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: CompactionWorld.unrestrictedModel))
    return TaskRouter(
      configuration: configuration, anthropic: standard, openRouter: unrestricted, credentials: DeviceCredentials(), store: store, requestGuard: requestGuard,
      now: clock.function)
  }

  func snapshot(_ job: EntityRef) async throws -> JobSnapshot {
    try #require(try await store.read { transaction in try JobSnapshot.load(job, in: transaction) })
  }

  func status(_ job: EntityRef) async throws -> JobStatus {
    JobStatus(try await snapshot(job), at: clock.instant)
  }

  func progress(_ job: EntityRef) async throws -> JobProgress {
    var progress = try engine.observe(job: job).makeAsyncIterator()
    return try #require(try await progress.next())
  }

  func waitUntilReached(_ hold: CallHold) async throws {
    try await engineEventually("device \(index)'s held call was sent") { hold.isReached }
  }
}

/// How a pair of partitioned replicas reconnects: which side's changes arrive first.
enum SyncOrder: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case firstToSecond
  case secondToFirst

  var testDescription: String { rawValue }
}

/// Two devices on one vault, the evaluation fixture's novel seeded on both and each device's consent granted. Replica 1's clocks run ten seconds ahead, so
/// its attempts start after replica 0's, the first writer while they are apart is replica 0 and the last is replica 1.
struct ChapterReplicas: Sendable {
  static let novel = EvalFixture.novel

  let reconciler: NovelForgeReconciler
  let replicas: CausalReplicas
  let devices: [ChapterDevice]

  static func make(seed: UInt64) async throws -> ChapterReplicas {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(count: 2, registry: Projection.registry, migrations: reconciler.migrations, order: .causal, reconciler: { _ in reconciler }, seed: seed))
    let novel = novel
    _ = try await replicas.write(0) { transaction in
      _ = try NovelRecord(id: novel, name: "The Lighthouse", wordTarget: EvalFixture.wordTarget).create(in: &transaction)
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction)
      _ = try ThreadRecord(novel: novel, thread: "lamp", summary: "What the lamp shows", openedChapter: 1, status: ThreadProgress(state: .known(.open)))
        .create(in: &transaction)
    }
    var devices = [ChapterDevice]()
    for index in 0..<2 {
      let consent = CompactionWorld.consent
      _ = try await replicas.write(index) { transaction in
        for host in ["api.example.com", "router.example.com"] {
          try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
        }
      }
      devices.append(ChapterDevice(index: index, store: await replicas.store(index)))
    }
    try await replicas.settle()
    let pair = ChapterReplicas(reconciler: reconciler, replicas: replicas, devices: devices)
    await pair.advance(1, by: 10)
    return pair
  }

  subscript(_ index: Int) -> ChapterDevice { devices[index] }

  /// Captures what the device's engine wrote straight to its store, so it can be delivered.
  func ship(_ index: Int) async throws {
    _ = try await replicas.write(index) { _ in }
  }

  func deliver(from writer: Int, to reader: Int) async throws {
    try await ship(writer)
    _ = try await replicas.deliver(from: writer, to: reader)
  }

  func sync(_ order: SyncOrder = .firstToSecond) async throws {
    try await ship(0)
    try await ship(1)
    switch order {
    case .firstToSecond:
      _ = try await replicas.deliver(from: 0, to: 1)
      _ = try await replicas.deliver(from: 1, to: 0)
    case .secondToFirst:
      _ = try await replicas.deliver(from: 1, to: 0)
      _ = try await replicas.deliver(from: 0, to: 1)
    }
    try await replicas.settle()
  }

  /// Moves both of the device's clocks, the lease clock its engine reads and the wall clock its store stamps changes with.
  func advance(_ index: Int, by seconds: Int) async {
    devices[index].clock.advance(TimeInterval(seconds))
    await replicas.advanceClock(of: index, by: .seconds(seconds))
  }

  /// The three checks every scenario ends on: both replicas hold one vault and derive the same tables, each is a rebuild, and each one's ledger is consistent.
  func expectConverged() async throws {
    try await sync()
    let digest = try await devices[0].store.loadState(.vault).digest
    let tables = try await Projection.derived(reconciler, in: devices[0].store)
    for device in devices {
      #expect(try await device.store.loadState(.vault).digest == digest, "replica \(device.index) holds another vault state")
      let comparison = try await Projection.compare(reconciler, in: device.store)
      let differing = comparison.incremental.keys.filter { comparison.incremental[$0] != comparison.rebuilt[$0] }.sorted()
      #expect(differing.isEmpty, "replica \(device.index) is not a rebuild: \(differing)")
      #expect((comparison.incremental[reconciler.faultTable] ?? []).isEmpty, "replica \(device.index) holds faults")
      let derived = try await Projection.derived(reconciler, in: device.store)
      let diverged = Set(tables.keys).union(derived.keys).filter { derived[$0] != tables[$0] }.sorted()
      #expect(diverged.isEmpty, "replica \(device.index) derives other tables: \(diverged)")
      try await ChapterLedger.expectConsistent(device.store, replica: device.index)
    }
  }
}

enum ChapterLedger {
  /// Every model call belongs to exactly one attempt that recorded it, every call an attempt recorded is in the ledger, and a succeeded attempt left no call
  /// open; an aborted call stays begun by design, its cost pending until the provider confirms it (LedgeredProvider).
  static func expectConsistent(_ store: VaultStore, replica index: Int) async throws {
    let (entries, attempts) = try await store.read { transaction in
      let attempts = try transaction.states(ofKind: JobSchema.attemptKind).compactMap { AttemptRecords.reading($0.state, of: $0.ref).record }
      return (try Ledger.entries(in: transaction), attempts)
    }
    let calls = Set(entries.filter { $0.parent == nil }.map(\.id))
    let claimed = attempts.flatMap(\.calls)
    #expect(Set(claimed).count == claimed.count, "replica \(index): a call is claimed by two attempts")
    #expect(Set(claimed) == calls, "replica \(index): the ledger's calls \(calls.count) are not the attempts' \(claimed.count)")
    let succeeded = Set(attempts.filter { $0.outcome == .succeeded }.flatMap(\.calls))
    let open = entries.filter { succeeded.contains($0.parent ?? $0.id) && $0.outcome == .started }
    #expect(open.isEmpty, "replica \(index): a succeeded attempt left \(open.count) calls open")
  }
}
