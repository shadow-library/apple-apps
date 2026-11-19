import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

private struct EngineCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: provider == .anthropic ? CompactionWorld.anthropic : CompactionWorld.openRouter, secret: "sk-test")
  }
}

struct EngineFixtureError: Error, CustomStringConvertible {
  let description: String
}

final class EngineClock: Sendable {
  static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

  private let date = Mutex(EngineClock.epoch)

  var function: @Sendable () -> Date { { self.date.withLock { $0 } } }

  var now: Date { date.withLock { $0 } }

  var instant: LeaseInstant { LeaseInstant(date: now, source: .device) }

  func advance(_ seconds: TimeInterval) {
    date.withLock { $0 = $0.addingTimeInterval(seconds) }
  }
}

/// A sleep that ends only when the test opens it, for the heartbeat and the engine's lease re-reads.
final class SleepGate: Sendable {
  private struct State {
    var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var pending = 0
  }

  private let state = Mutex(State())

  var waiting: Int { state.withLock { $0.waiters.count } }

  func sleep() async throws {
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let ready = state.withLock { state -> Bool in
          if Task.isCancelled { return true }
          guard state.pending == 0 else {
            state.pending -= 1
            return true
          }
          state.waiters[id] = continuation
          return false
        }
        guard ready else { return }
        Task.isCancelled ? continuation.resume(throwing: CancellationError()) : continuation.resume()
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
    }
  }

  /// Wakes every sleeper, or the next one when none sleeps yet.
  func open() {
    let waiters = state.withLock { state in
      defer { state.waiters = [:] }
      if state.waiters.isEmpty { state.pending += 1 }
      return Array(state.waiters.values)
    }
    for waiter in waiters { waiter.resume() }
  }
}

/// Two steps that each send one chapter call through `ChapterCallRoute.run`, read the attempt's pinned writer pack and append one Notebook entry whose id
/// comes from the job and step, so a second write of one step's output would be a second change to the same entry.
struct FakeChapterStep: JobStep {
  static let schema: JSONValue = ["type": "object", "properties": ["body": ["type": "string"]], "required": ["body"]]

  let name: String
  let next: String?

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    guard let text = state["text"]?.stringValue else { throw EngineFixtureError(description: "the checkpoint holds no text") }
    let (pack, disclosure) = try await context.writerPack(WriterPackOptions())
    let route = try ChapterCallRouter.route(
      ChapterCallSource(novel: context.target.novel, chapter: context.target.chapter, role: .draft, plan: nil, isolated: false), unrestrictedAvailable: false)
    let result = try await context.call(
      route, pace: .steady, screening: OrderedJSONObject([("text", .string(text))]),
      request: { $0.request(system: [ContextSegment(text: pack.renderedStable.isEmpty ? "Write." : pack.renderedStable)], messages: [.user(text)]) },
      name: "fake-\(name)", schema: Self.schema)
    guard let body = (try? CanonicalJSON.decode(result.json))?["body"]?.stringValue else { throw EngineFixtureError(description: "the reply has no body") }
    let output = "\(text)>\(name):\(body)"
    let entry = NotebookEntryRecord(
      id: Self.entryID(job: context.attempt.job.ref, step: name), novel: context.target.novel, entryKind: .known(.decision), topic: name, statement: output,
      why: withholdings(of: disclosure), stepKey: name)
    return AttemptStepOutput(state: ["text": .string(output)], next: next) { transaction in _ = try entry.append(in: &transaction) }
  }

  static func entryID(job: EntityRef, step: String) -> UUID {
    let hex = Array(sha256Hex("\(job.key.rawValue)|\(step)"))
    let text = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-4" + String(hex[13..<16]) + "-8" + String(hex[17..<20]) + "-" + String(hex[20..<32])
    return UUID(uuidString: text) ?? UUID()
  }
}

/// The disclosure policy's withholdings, for comparing a policy rebuilt after a resume with the one the pack was built with.
func withholdings(of policy: WriterDisclosurePolicy) -> String {
  (policy.lockedFacts.map(\.factKey) + policy.withholdings.map { "\($0.pattern)|\($0.weight)|\($0.copyFieldsOnly)|\($0.possibleWeights)" }).joined(separator: "\n")
}

final class PackCounter: Sendable {
  private let state = Mutex<(builds: Int, withholdings: [String])>((0, []))

  var builds: Int { state.withLock { $0.builds } }

  /// The withholdings of each build's policy.
  var built: [String] { state.withLock { $0.withholdings } }

  func builder(_ store: VaultStore) -> WriterPackBuilder {
    let build = vaultWriterPack(store)
    return { novel, chapter, options throws(WriterPackError) in
      let built = try await build(novel, chapter, options)
      self.state.withLock { state in
        state.builds += 1
        state.withholdings.append(withholdings(of: built.disclosure))
      }
      return built
    }
  }
}

extension AttemptRunner.Faults {
  static func once(at point: Point) -> Self {
    let fired = Mutex(false)
    return Self { reached in
      guard reached == point else { return false }
      return fired.withLock { fired in
        defer { fired = true }
        return !fired
      }
    }
  }
}

struct JobEngineWorld {
  static let pipelineVersion = 1
  static let expected = ["draft": "seed>draft:ok", "polish": "seed>draft:ok>polish:ok"]
  static let pipeline = NovelPipeline(
    version: pipelineVersion, first: "draft", steps: ["draft": FakeChapterStep(name: "draft", next: "polish"), "polish": FakeChapterStep(name: "polish", next: nil)])

  let novel = SchemaFixture.novel
  let clock = EngineClock()
  let store: VaultStore
  let provider: ScriptedModelProvider
  let heartbeat = SleepGate()
  let rereads = SleepGate()
  let packs = PackCounter()

  init(store: VaultStore? = nil, provider: ScriptedModelProvider = ScriptedModelProvider()) async throws {
    let store = try store ?? Projection.store(try Projection.reconciler())
    self.store = store
    self.provider = provider
    let novel = novel
    try await store.write { transaction in
      if try NovelRecord.read(id: novel, in: transaction) == .absent {
        _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
        _ = try SecretRecord(novel: novel, secret: "heir", text: "Mara is the heir.", revealChapter: 3).create(in: &transaction)
      }
      for host in ["api.example.com", "router.example.com"] {
        try AIConsent.decide(
          .granted, provider: host, dataClass: CompactionWorld.consent.dataClass, summary: CompactionWorld.consent.disclosure, atMillis: 1, in: &transaction)
      }
    }
  }

  static func reply(_ body: String = "ok") -> [ScriptedModelProvider.Step] {
    ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(["body": .string(body)]), as: UTF8.self))
  }

  /// A call that never answers, as a request in flight when the process ends; it ends only when cancelled.
  static let frozen: [ScriptedModelProvider.Step] = [.event(.started(requestID: "frozen", generationID: nil)), .delay(.seconds(3600))]

  func router(_ requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?) -> TaskRouter {
    guard let standard = ProviderBinding(origin: CompactionWorld.anthropic, provider: provider),
      let unrestricted = ProviderBinding(origin: CompactionWorld.openRouter, provider: provider)
    else { preconditionFailure("valid bindings") }
    let configuration = TaskRouterConfiguration(provider: .anthropic, assignments: OpenRouterAssignments(unrestricted: CompactionWorld.unrestrictedModel))
    return TaskRouter(
      configuration: configuration, anthropic: standard, openRouter: unrestricted, credentials: EngineCredentials(), store: store, requestGuard: requestGuard,
      now: clock.function)
  }

  func runner(_ faults: AttemptRunner.Faults = .none) -> AttemptRunner {
    let heartbeat = heartbeat
    let timing = AttemptRunner.Timing(heartbeat: LeaseTerms.heartbeat) { _ in try await heartbeat.sleep() }
    return AttemptRunner(store: store, clock: LeaseClock(trusted: nil, device: clock.function), timing: timing, faults: faults)
  }

  func engine(
    _ faults: AttemptRunner.Faults = .none, engineFaults: JobEngine.Faults = .none,
    catalog: @escaping @Sendable (NovelJobKind) -> NovelPipelineDefinition = { _ in .ready(JobEngineWorld.pipeline) }, unrestrictedAvailable: Bool = false
  ) throws -> JobEngine {
    let world = self
    let rereads = rereads
    return try JobEngine(
      store: store, router: { world.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil, device: clock.function), runner: runner(faults),
      catalog: catalog, packs: packs.builder(store), timing: JobEngine.Timing { _ in try await rereads.sleep() }, faults: engineFaults, unrestrictedAvailable: unrestrictedAvailable
    )
  }

  func request(_ engine: JobEngine, chapter: Int = 1, rerun: Bool = false) async throws -> JobKey {
    try await engine.request(NovelJobRequest(kind: .generate, novel: novel, chapter: chapter, fingerprint: "f:\(chapter)", payload: ["text": "seed"], rerun: rerun))
  }

  func attempt(_ id: AttemptID) async throws -> AttemptRecord {
    try #require(try await store.read { transaction in try AttemptRecords.read(id, in: transaction) }.record)
  }

  func status(_ job: EntityRef) async throws -> JobStatus {
    let snapshot = try #require(try await store.read { transaction in try JobSnapshot.load(job, in: transaction) })
    return JobStatus(snapshot, at: clock.instant)
  }

  func ledgerIDs() async throws -> [UUID] {
    try await store.read { transaction in try Ledger.entries(in: transaction) }.filter { $0.parent == nil }.map(\.id)
  }

  func localRuns() async throws -> [LocalRun] {
    let replica = store.replica
    return try await store.read { transaction in try JobsLocal.runs(of: replica, in: transaction.database) }
  }

  func pinnedPacks() async throws -> Int {
    try await store.read { transaction in
      guard try transaction.database.tableExists(WriterPackPins.table) else { return 0 }
      return try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM \(WriterPackPins.table)") ?? 0
    }
  }

  /// Each step's Notebook entry, the withholdings its step scrubbed with, and how many changes it received over the whole unsent log.
  func outputs(of job: EntityRef) async throws -> (texts: [String: String], withholdings: [String: String], writes: [String: Int]) {
    var writes: [String: Int] = [:]
    for change in try await store.pendingChanges(limit: Int.max) {
      let record = try ChangeRecord(json: try CanonicalJSON.decode(change.line))
      for step in Self.expected.keys where record.ref == NotebookEntryRecord.ref(FakeChapterStep.entryID(job: job, step: step)) {
        writes[step, default: 0] += 1
      }
    }
    let novel = novel
    let entries = try await store.read { transaction in try NotebookEntryRecord.listing(novel: novel, in: transaction).entries.map(\.record) }
    let texts = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.stepKey.map { ($0, entry.statement) } })
    let withheld = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.stepKey.map { ($0, entry.why ?? "") } })
    return (texts, withheld, writes)
  }

  func expectOutputsWrittenOnce(_ job: EntityRef, steps: Set<String> = Set(JobEngineWorld.expected.keys)) async throws {
    let (texts, _, writes) = try await outputs(of: job)
    #expect(texts == Self.expected.filter { steps.contains($0.key) })
    #expect(writes == Dictionary(uniqueKeysWithValues: steps.map { ($0, 1) }))
  }

  func waitForRequests(_ count: Int) async throws {
    try await engineEventually("\(count) requests reached the provider") { provider.requests.count >= count }
  }
}

func engineEventually(_ what: String, timeout: Duration = .seconds(120), _ condition: @Sendable () async throws -> Bool) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(5))
  }
  throw EngineFixtureError(description: "timed out waiting until \(what)")
}
