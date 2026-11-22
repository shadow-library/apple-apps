import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import SwiftUI
import Synchronization
import Testing

@testable import NovelForge

private struct JobsCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

@MainActor
private final class PowerLog {
  var begun = 0
  var ended = 0

  var activity: JobPowerAssertion.Activity {
    JobPowerAssertion.Activity(
      begin: { [self] in
        begun += 1
        return NSObject()
      },
      end: { [self] _ in ended += 1 })
  }
}

/// A starter that refuses every start, counting them by job.
private final class RefusingStarter: Sendable {
  private let counts = Mutex<[EntityRef: Int]>([:])

  func count(_ job: EntityRef) -> Int { counts.withLock { $0[job] ?? 0 } }

  var starter: JobEngineCalls.Start {
    { [self] _, job throws(JobEngineError) in
      counts.withLock { $0[job, default: 0] += 1 }
      throw .pipelineNotYetAvailable(.generate)
    }
  }
}

/// A starter that holds its first start until opened, recording how many starts ever ran at once; every start is refused.
private final class HeldStarter: Sendable {
  private struct State {
    var calls = 0
    var inFlight = 0
    var most = 0
    var held: CheckedContinuation<Void, Never>?
    var isOpen = false
  }

  private let state = Mutex(State())

  var calls: Int { state.withLock { $0.calls } }
  var most: Int { state.withLock { $0.most } }
  var isHolding: Bool { state.withLock { $0.held != nil } }

  func open() {
    let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.isOpen = true
      defer { state.held = nil }
      return state.held
    }
    held?.resume()
  }

  var starter: JobEngineCalls.Start {
    { [self] _, _ throws(JobEngineError) in
      let first = state.withLock { state -> Bool in
        state.calls += 1
        state.inFlight += 1
        state.most = max(state.most, state.inFlight)
        return state.calls == 1 && !state.isOpen
      }
      if first {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let resume = state.withLock { state -> Bool in
            guard !state.isOpen else { return true }
            state.held = continuation
            return false
          }
          if resume { continuation.resume() }
        }
      }
      state.withLock { $0.inFlight -= 1 }
      throw .pipelineNotYetAvailable(.generate)
    }
  }
}

private final class InterruptLog: Sendable {
  let jobs = Mutex<[EntityRef]>([])
}

private final class StartLog: Sendable {
  let runs = Mutex<[EntityRef]>([])
  let resumes = Mutex<[EntityRef]>([])
}

/// A host that keeps every run it is handed and counts the scene's moves.
@MainActor
private final class RecordingHost: JobRunHost {
  private(set) var runs: [HostedJobRun] = []
  private(set) var backgrounds = 0
  private(set) var actives = 0

  func host(_ run: HostedJobRun) { runs.append(run) }
  func sceneEnteredBackground() { backgrounds += 1 }
  func sceneBecameActive() { actives += 1 }
}

/// A vault with one novel whose job runtime calls a scripted model.
@MainActor
private struct JobsWorld {
  let store: VaultStore
  let novel: UUID
  let provider: ScriptedModelProvider
  let power: PowerLog
  let host: String
  let makeEngine: JobRuntime.EngineFactory
  let runtime: JobRuntime

  static func make(
    _ calls: [[ScriptedModelProvider.Step]] = [], at location: StoreLocation = .inMemory, granted: Bool = true, engine: JobEngineCalls = JobEngineCalls(),
    host: any JobRunHost = ForegroundRunHost(), settler: ((VaultStore) -> CostSettler)? = nil
  ) async throws -> JobsWorld {
    let store =
      switch location {
      case .file(let url): try NovelForgeStore.open(at: url)
      case .inMemory: try NovelForgeStore.openInMemory()
      }
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let provider = ScriptedModelProvider(calls: calls)
    guard let origin = URL(string: "https://api.anthropic.com"), let binding = ProviderBinding(origin: origin, provider: provider) else { throw ChatFixtureError.noBinding }
    let consent = ConsentDisclosure.novelText
    let clock = LeaseClock(trusted: nil)
    let power = PowerLog()
    let makeEngine: JobRuntime.EngineFactory = { () throws(JobEngineError) -> JobEngine in
      try JobEngine(
        store: store,
        router: { requestGuard in
          TaskRouter(
            configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: JobsCredentials(), store: store,
            requestGuard: requestGuard)
        }, consent: consent.requirement, clock: clock)
    }
    let assertion = JobPowerAssertion(activity: power.activity)
    let settler = settler?(store)
    let runtime = JobRuntime(
      store: store, clock: clock, platform: .mac, power: assertion, takeOverDelay: .milliseconds(20), settler: settler, host: host, calls: engine,
      makeEngine: makeEngine)
    let world = JobsWorld(store: store, novel: novel, provider: provider, power: power, host: binding.host, makeEngine: makeEngine, runtime: runtime)
    if granted { try await world.decideConsent(.granted, at: 1) }
    return world
  }

  /// Through an engine of its own that gives the vault's jobs lock up again, since the runtime has not launched.
  func requestWithoutTheRuntime(_ request: NovelJobRequest) async throws -> EntityRef {
    let engine = try makeEngine()
    return try await engine.request(request).ref
  }

  func decideConsent(_ state: AIConsentState, at millis: Int64) async throws {
    let (consent, host) = (ConsentDisclosure.novelText, host)
    try await store.write { transaction in
      try AIConsent.decide(state, provider: host, dataClass: consent.dataClass, summary: consent.id, atMillis: millis, in: &transaction)
    }
  }

  func approvedChapter() async throws {
    let novel = novel
    let saved = try await store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "The tide came in."), base: nil, at: Date(), in: &transaction)
    }
    guard case .committed(let revision) = saved else { throw ChatFixtureError.noBinding }
    try await store.approveChapter(novel: novel, chapter: 1, revision: revision)
  }

  func generation(_ fingerprint: String = "runtime-test", chapter: Int = 1) -> NovelJobRequest {
    NovelJobRequest(kind: .generate, novel: novel, chapter: chapter, fingerprint: fingerprint)
  }

  func status() async throws -> ChapterWorkspaceStatus {
    let row = try await store.load(ChapterList.self, novel).rows.value?.first { $0.chapter == 1 }
    let board = try await store.load(ChapterJobBoard.self, ChapterJobBoardQuery(novel: novel, chapter: 1, replica: store.replica, now: runtime.clock.now()))
    return ChapterWorkspaceStatus(row: row, board: board, replica: store.replica, standing: runtime.standing)
  }

  func attempts(of job: EntityRef) async throws -> Int {
    try await store.load(JobDetail.self, JobDetailQuery(job: job, now: runtime.clock.now())).attempts.value?.count ?? 0
  }

  func failedLine() async throws -> ChapterJobLine {
    var found: ChapterJobLine?
    try await JobsWait.until("the chapter shows a failed job") {
      found = try await status().lines.first { if case .failed = $0.state { true } else { false } }
      return found != nil
    }
    return try #require(found)
  }
}

@MainActor
enum JobsWait {
  static func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
    for _ in 0..<12_000 {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }
}

@MainActor
@Suite("Job runtime")
struct JobsRuntimeTests {
  @Test func shouldRunAnApprovalsReadFromTheBacklogAndReadItAgainAfterItFails() async throws {
    let world = try await JobsWorld.make([[.failure(.server(status: 500))], [.failure(.server(status: 500))]])
    try await world.approvedChapter()
    await world.runtime.launch()
    #expect(world.runtime.mode == .running)

    let line = try await world.failedLine()
    #expect(line.kind == .finalizeReview && line.actions == [.retryRead])
    #expect(try await world.attempts(of: line.job) == 1)
    try await JobsWait.until("the power assertion is released") { world.power.begun == 1 && world.power.ended == 1 }

    #expect(await world.runtime.retryRead(novel: world.novel, chapter: 1, shown: line.job) == nil)
    try await JobsWait.until("the second read starts") { try await world.attempts(of: line.job) == 2 }
    let again = try await world.failedLine()
    #expect(again.job == line.job && world.provider.requests.count == 2)
    try await JobsWait.until("the power assertion is released again") { world.power.begun == 2 && world.power.ended == 2 }
    #expect(!world.runtime.isHoldingPower)
  }

  @Test func shouldPriceAPendingEntryOnceAnAttemptEndsAndLeftoversAtLaunch() async throws {
    let (transport, passes) = (CostWorld.reply(200), PassCount())
    let world = try await JobsWorld.make(settler: { CostWorld.settler(store: $0, transport: transport, passes: passes) })
    let costs = CostWorld(store: world.store, transport: transport, passes: passes)
    let leftover = try await costs.addPending(generation: "gen-left")
    await world.runtime.launch()
    try await JobsWait.until("the leftover is priced at launch") { try await costs.source(of: leftover) == .reported }
    try await JobsWait.until("the launch pass ends") { passes.count == 1 }

    let engine = try #require(world.runtime.engine)
    let late = try await costs.addPending(generation: "gen-late")
    let job = try await engine.request(world.generation()).ref
    _ = try await world.failedLine()
    try await JobsWait.until("the attempt's entry is priced") { try await costs.source(of: late) == .reported }
    #expect(try await world.attempts(of: job) == 1)
    #expect(transport.requests.count == 2)
  }

  @Test func shouldStartNothingWithoutConsentAndRunTheJobOnceItIsGiven() async throws {
    let world = try await JobsWorld.make([[.failure(.server(status: 500))]], granted: false)
    try await world.approvedChapter()
    await world.runtime.launch()

    try await JobsWait.until("the runtime waits for consent") { world.runtime.consentNeeded != nil }
    #expect(world.runtime.consentNeeded?.host == world.host)
    let waiting = try #require(try await world.status().lines.first)
    #expect(waiting.kind == .finalizeReview && waiting.state == .waitingForConsent && waiting.actions == [.allow, .cancel])
    #expect(try await world.attempts(of: waiting.job) == 0 && world.provider.requests.isEmpty)

    try await world.decideConsent(.granted, at: 2)
    try await JobsWait.until("the job runs once consent is given") { try await world.attempts(of: waiting.job) == 1 }
    #expect(world.runtime.consentNeeded == nil)
  }

  @Test func shouldRunAFailedGenerationAgainWithTryAgain() async throws {
    let world = try await JobsWorld.make()
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    let job = try await engine.request(world.generation()).ref

    let line = try await world.failedLine()
    #expect(line.job == job && line.kind == .generate && line.actions == [.tryAgain])
    #expect(try await world.attempts(of: job) == 1)

    #expect(await world.runtime.tryAgain(job) == nil)
    try await JobsWait.until("a second attempt of the same run starts") { try await world.attempts(of: job) == 2 }
    #expect(try await world.failedLine().job == job)
  }

  @Test func shouldTryARefusedStartOncePerDistinctQueue() async throws {
    let refusing = RefusingStarter()
    let world = try await JobsWorld.make(engine: JobEngineCalls(run: refusing.starter))
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    let first = try await engine.request(world.generation("first")).ref
    try await JobsWait.until("the first job is tried") { refusing.count(first) == 1 }

    let unrelated = try JobKey(scope: "elsewhere", kind: "generate", target: "chapter:1", fingerprint: "f", run: 1)
    _ = try await world.store.write { transaction in
      try JobRecords.request(JobRequest(key: unrelated, payload: .null, replica: ReplicaID(UUID.v7())), in: &transaction)
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(refusing.count(first) == 1)

    let second = try await engine.request(world.generation("second", chapter: 2)).ref
    try await JobsWait.until("the queue changed, so both are tried") { refusing.count(second) == 1 && refusing.count(first) == 2 }
  }

  @Test func shouldNeverStartASecondJobWhileOneRunsHoweverOftenTheQueueIsArmedAgain() async throws {
    let held = HeldStarter()
    let world = try await JobsWorld.make(granted: false, engine: JobEngineCalls(run: held.starter))
    await world.runtime.launch()
    let engine = try #require(world.runtime.engine)
    _ = try await engine.request(world.generation("first"))
    try await JobsWait.until("the first start is held") { held.isHolding }

    let second = try await engine.request(world.generation("second", chapter: 2)).ref
    #expect(await world.runtime.runHere(second) == nil)
    #expect(world.runtime.consentNeeded != nil)
    world.runtime.consentAllowed()
    try await Task.sleep(for: .milliseconds(300))
    #expect(held.calls == 1)

    held.open()
    try await JobsWait.until("the queue is started again after the held start ends") { held.calls >= 3 }
    #expect(held.most == 1)
  }

  @Test func shouldFollowOneRunOnceHoweverOftenItIsHandedOver() async throws {
    let world = try await JobsWorld.make()
    let engine = try world.makeEngine()
    let job = try await engine.request(world.generation()).ref
    let handle = try await engine.run(job: job)

    world.runtime.follow(handle, origin: .person)
    world.runtime.follow(handle, origin: .person)
    #expect(world.power.begun == 1)
    _ = await handle.result
    try await JobsWait.until("the run's end releases the assertion") { world.power.ended == 1 }
    #expect(world.power.begun == 1 && !world.runtime.isHoldingPower)
  }

  @Test func shouldEndThePowerActivityWhenTheRuntimeShutsDown() async throws {
    let world = try await JobsWorld.make()
    let engine = try world.makeEngine()
    let handle = try await engine.run(job: try await engine.request(world.generation()).ref)
    world.runtime.follow(handle, origin: .person)
    world.runtime.shutDown()
    #expect(world.power.ended == 1 && !world.runtime.isHoldingPower)
    _ = await handle.result
    try await Task.sleep(for: .milliseconds(50))
    #expect(world.power.ended == 1)
  }

  @Test func shouldRunNothingWhileAnotherCopyHoldsTheVaultThenTakeItOver() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "JobsRuntimeTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let world = try await JobsWorld.make(at: .file(directory.appending(path: "vault.sqlite")))
    let otherCopy = try #require(try world.store.acquireProcessLock(.jobs))
    await world.runtime.launch()
    #expect(world.runtime.mode == .elsewhere && !world.runtime.runsJobs && world.runtime.here == .elsewhere)
    #expect(await world.runtime.runHere(try JobKey(scope: "s", kind: "generate", target: "chapter:1", fingerprint: "f", run: 1).ref) == JobsErrors.notRunningHere)

    otherCopy.release()
    try await JobsWait.until("the runtime takes the vault over") { world.runtime.mode == .running }
    #expect(try world.store.acquireProcessLock(.jobs) == nil)
    world.runtime.shutDown()
  }

  @Test func shouldHandEveryRunItFollowsToTheHostWithItsInterruptAndTellItOfTheScene() async throws {
    let (host, interrupted) = (RecordingHost(), InterruptLog())
    let engine = JobEngineCalls(interrupt: { _, job throws(JobEngineError) in
      interrupted.jobs.withLock { $0.append(job) }
      return .ended
    })
    let world = try await JobsWorld.make([[.failure(.server(status: 500))]], engine: engine, host: host)
    await world.runtime.launch()
    let job = try await #require(world.runtime.engine).request(world.generation()).ref

    try await JobsWait.until("the run is handed to the host") { !host.runs.isEmpty }
    let run = try #require(host.runs.first)
    #expect(run.job == job && host.runs.count == 1)
    #expect(run.target == NovelJobTarget(novel: world.novel, chapter: 1, kind: .generate) && run.origin == .person)
    guard case .settled(.failed) = await run.finished() else {
      Issue.record("the run should end failed")
      return
    }
    for await _ in run.progress {}
    #expect(try await run.interrupt() == .ended && interrupted.jobs.withLock { $0 } == [job])

    world.runtime.sceneEnteredBackground()
    await world.runtime.sceneBecameActive()
    #expect(host.backgrounds == 1 && host.actives == 1)
  }

  @Test func shouldHandAJobQueuedBeforeLaunchAsAutomaticAndOneAskedForSinceAsAPersons() async throws {
    let host = RecordingHost()
    let world = try await JobsWorld.make([[.failure(.server(status: 500))], [.failure(.server(status: 500))]], host: host)
    let before = try await world.requestWithoutTheRuntime(world.generation("before"))
    await world.runtime.launch()
    try await JobsWait.until("the queued job is handed over") { host.runs.contains { $0.job == before } }
    let since = try await #require(world.runtime.engine).request(world.generation("since", chapter: 2)).ref
    try await JobsWait.until("the job asked for since launch is handed over") { host.runs.contains { $0.job == since } }

    #expect(host.runs.first { $0.job == before }?.origin == .automatic)
    #expect(host.runs.first { $0.job == since }?.origin == .person)
  }

  @Test func shouldHandAJobQueuedBeforeLaunchAsAPersonsOnceConsentIsGivenHere() async throws {
    let host = RecordingHost()
    let world = try await JobsWorld.make([[.failure(.server(status: 500))]], granted: false, host: host)
    let before = try await world.requestWithoutTheRuntime(world.generation("before"))
    await world.runtime.launch()
    try await JobsWait.until("the start waits for consent") { world.runtime.consentNeeded != nil }

    world.runtime.consentAllowed()
    try await world.decideConsent(.granted, at: 2)
    try await JobsWait.until("the job is handed over") { host.runs.contains { $0.job == before } }
    #expect(host.runs.first { $0.job == before }?.origin == .person)
  }

  @Test func shouldStartNothingMoreAndInterruptTheRunGoingHereWhenStoppingBeforeQuitting() async throws {
    let (interrupted, starts) = (InterruptLog(), StartLog())
    let engine = JobEngineCalls(
      run: { engine, job throws(JobEngineError) in
        starts.runs.withLock { $0.append(job) }
        return try await engine.run(job: job)
      },
      resumeHere: { engine, job throws(JobEngineError) in
        starts.resumes.withLock { $0.append(job) }
        return try await engine.resumeHere(job: job)
      },
      interrupt: { engine, job throws(JobEngineError) in
        interrupted.jobs.withLock { $0.append(job) }
        return try await engine.interrupt(job: job, releasingLease: true)
      })
    let world = try await JobsWorld.make([[.delay(.seconds(60))], [.delay(.seconds(60))]], engine: engine)
    let (replica, since) = (world.store.replica, world.runtime.clock.now())
    try await world.store.write { transaction in try WorkerRecords.designate(replica, at: since, in: &transaction) }
    try await world.approvedChapter()
    await world.runtime.launch()
    try await JobsWait.until("the read's model call is under way") { !world.provider.requests.isEmpty }
    let run = try #require(world.runtime.runsHere.first)
    #expect(world.runtime.runsHere.count == 1)
    var progress = world.runtime.observeRun(run.attempt).makeAsyncIterator()
    #expect(await progress.next()?.attempt == run.attempt)
    let queued = try await #require(world.runtime.engine).request(world.generation()).ref

    await world.runtime.stopBeforeQuitting()

    #expect(interrupted.jobs.withLock { $0 } == [run.job])
    try await JobsWait.until("the interrupted run is no longer going here") { world.runtime.runsHere.isEmpty }
    try await JobsWait.until("the power assertion is released") { world.power.ended == 1 }
    try await Task.sleep(for: .milliseconds(500))
    #expect(starts.runs.withLock { $0 } == [run.job] && starts.resumes.withLock { $0 }.isEmpty)
    #expect(!starts.runs.withLock { $0 }.contains(queued) && world.runtime.runsHere.isEmpty && world.provider.requests.count == 1)
    var ended = world.runtime.observeRun(run.attempt).makeAsyncIterator()
    #expect(await ended.next() == nil)
    #expect(await world.runtime.runHere(queued) == JobsErrors.notRunningHere)
  }

  @Test func shouldShowARunGoingInThisProcessAsRunningNotAsStopped() async throws {
    let world = try await GenerationWorld.make([[.delay(.seconds(60))] + GenerationScripts.draft()])
    await world.runtime.launch()
    #expect(await GenerationModel(novel: world.novel, chapter: 1).start(.generate, options: GenerationOptions(), runtime: world.runtime) == .started)
    try await JobsWait.until("the run's model call is under way") { !world.provider.requests.isEmpty }

    await world.runtime.sceneBecameActive()

    #expect(world.runtime.resumable.isEmpty)
    let line = try #require(try await world.status().lines.first)
    guard case .runningHere = line.state else {
      Issue.record("a run going here should read as running here")
      return
    }
    #expect(line.actions == [.cancel])
    #expect(await world.runtime.cancel(line.job) == nil)
  }

  @Test func shouldTellTheHostWhenTheSceneGoesToTheBackgroundAndComesBack() async throws {
    let host = RecordingHost()
    let runtimes = JobRuntimes(host: host)
    let services = AIServices.novelForge(defaults: try #require(UserDefaults(suiteName: "JobsRuntimeTests-\(UUID().uuidString)")))
    await runtimes.phaseChanged(.background)
    #expect(host.backgrounds == 0)

    _ = runtimes.runtime(for: try NovelForgeStore.openInMemory(), services: services, trustedClock: TrustedClock())
    await runtimes.phaseChanged(.background)
    await runtimes.phaseChanged(.inactive)
    await runtimes.phaseChanged(.active)

    #expect(host.backgrounds == 1 && host.actives == 1)
  }

  @Test func shouldStampAndReadLeasesWithTheVaultsTrustedClock() async throws {
    let runtimes = JobRuntimes()
    let services = AIServices.novelForge(defaults: try #require(UserDefaults(suiteName: "JobsRuntimeTests-\(UUID().uuidString)")))
    let trusted = TrustedClock()
    let ahead = Date().addingTimeInterval(3600)
    trusted.record(serverDate: ahead)

    let now = runtimes.runtime(for: try NovelForgeStore.openInMemory(), services: services, trustedClock: trusted).clock.now()

    #expect(now.source == .trusted && abs(now.date.timeIntervalSince(ahead)) < 60)
  }

  @Test func shouldKeepOneRuntimePerVaultAndLetViewsOnlyReadIt() async throws {
    let runtimes = JobRuntimes()
    let services = AIServices.novelForge(defaults: try #require(UserDefaults(suiteName: "JobsRuntimeTests-\(UUID().uuidString)")))
    let store = try NovelForgeStore.openInMemory()
    #expect(runtimes.existing(for: store) == nil)
    let clock = TrustedClock()
    let runtime = runtimes.runtime(for: store, services: services, trustedClock: clock)
    #expect(runtimes.runtime(for: store, services: services, trustedClock: clock) === runtime && runtimes.existing(for: store) === runtime)
    #expect(runtimes.runtime(for: try NovelForgeStore.openInMemory(), services: services, trustedClock: clock) !== runtime)
    #expect(runtimes.existing(for: store) == nil)
  }

  @Test func shouldHoldThePowerAssertionWhileAnyRunIsFollowed() {
    let log = PowerLog()
    let power = JobPowerAssertion(activity: log.activity)
    power.begin()
    power.begin()
    power.end()
    #expect(power.isHeld && log.begun == 1 && log.ended == 0)
    power.end()
    power.end()
    #expect(!power.isHeld && log.begun == 1 && log.ended == 1)
  }
}
