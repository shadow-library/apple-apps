import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A wait a step cannot be cancelled out of, as a step that ignores cancellation: it ends only when the test opens it.
final class StepLatch: Sendable {
  private struct State {
    var open = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var stopping: (@Sendable () -> Bool)?
  }

  private let state = Mutex(State())

  var isReached: Bool { state.withLock { $0.stopping != nil } }

  var isStopping: Bool { state.withLock { $0.stopping }?() ?? false }

  func wait(_ context: JobStepContext) async {
    let attempt = context.attempt
    state.withLock { $0.stopping = { attempt.isStopping } }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let open = state.withLock { state in
        if !state.open { state.waiters.append(continuation) }
        return state.open
      }
      if open { continuation.resume() }
    }
  }

  func open() {
    let waiters = state.withLock { state in
      state.open = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}

/// Waits on the latch the first time it runs, then runs its step.
struct LatchedStep: JobStep {
  let latch: StepLatch
  let inner: any JobStep

  func run(_ state: JSONValue, in context: JobStepContext) async throws -> AttemptStepOutput {
    if !latch.isReached { await latch.wait(context) }
    return try await inner.run(state, in: context)
  }
}

extension JobEngineWorld {
  static let course = PipelineCourse(["draft", "polish"], tasks: ["draft": .writing, "polish": .writing])

  static func latched(_ latch: StepLatch) -> NovelPipeline {
    NovelPipeline(
      version: pipelineVersion, first: "draft",
      steps: ["draft": LatchedStep(latch: latch, inner: FakeChapterStep(name: "draft", next: "polish")), "polish": FakeChapterStep(name: "polish", next: nil)],
      course: course)
  }

  var target: NovelJobTarget { NovelJobTarget(novel: novel, chapter: 1, kind: .generate) }
}

/// The code of the engine's refusal, or nil when the body did not throw one.
func refusal(_ body: () async throws -> Void) async -> String? {
  do {
    try await body()
    return nil
  } catch {
    return (error as? JobEngineError)?.code
  }
}

@Suite("Job engine: interrupt and resume here", TestTimeLimit.standard)
struct JobEngineHandOffTests {
  @Test func shouldInterruptARunAndResumeItHereFromItsCheckpoint() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let first = try await engine.run(job: job)
    try await world.waitForRequests(2)
    #expect(try await engine.interrupt(job: job, releasingLease: false) == .interrupted(first.attempt))
    #expect(await first.result == .interrupted)
    try await world.expectOutputsWrittenOnce(job, steps: ["draft"])
    let polish = AttemptStep(name: "polish", index: 1)
    #expect(try await engine.interruptedRuns() == [InterruptedJobRun(attempt: first.attempt, job: job, target: world.target, step: polish)])
    #expect(try await world.attempt(first.attempt).isLive(at: world.clock.instant), "a lease not released stays live")

    world.provider.enqueue(JobEngineWorld.reply())
    let resumed = try await engine.resumeHere(job: job)
    #expect(resumed.attempt == first.attempt)
    #expect(await resumed.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce(job)
    let attempt = try await world.attempt(first.attempt)
    let ledger = try await world.ledgerIDs()
    #expect(attempt.calls.count == 3 && attempt.calls == ledger)
    #expect(world.packs.builds == 1)
    #expect(try await engine.interruptedRuns().isEmpty)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .ended)
    #expect(try await world.localRuns().isEmpty)
  }

  @Test func shouldReleaseTheLeaseOfARunNoLongerGoingHere() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await world.waitForRequests(1)
    #expect(try await engine.interrupt(job: job, releasingLease: false) == .interrupted(handle.attempt))
    #expect(await handle.result == .interrupted)
    world.clock.advance(1)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .notRunning(handle.attempt))
    let attempt = try await world.attempt(handle.attempt)
    #expect(attempt.lease?.expires == world.clock.instant.millis)
    #expect(!attempt.isLive(at: world.clock.instant))
    #expect(try await world.status(job) == .queued)
    #expect(try await engine.interruptedRuns().map(\.attempt) == [handle.attempt], "the checkpoint stays for Resume")
  }

  @Test func shouldAnswerSettlingForAStopMarkedRunAndSettleItWithoutResuming() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.frozen]))
    let engine = try world.engine(.once(at: .settling))
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await world.waitForRequests(1)
    #expect(try await engine.cancel(job: job) == .requested)
    #expect(await handle.result == .interrupted)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .settling(handle.attempt))
    #expect(try await engine.interruptedRuns().isEmpty)
    #expect(await refusal { _ = try await engine.resumeHere(job: job) } == JobEngineError.nothingToResume(job).code)
    #expect(try await engine.settleStoppedAttempts() == [handle.attempt])
    #expect(try await world.status(job) == .cancelled)
    #expect(try await world.localRuns().isEmpty)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .ended)
  }

  @Test func shouldRefuseToResumeOrInterruptWhatThisDeviceDoesNotHold() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    #expect(await refusal { _ = try await engine.resumeHere(job: job) } == JobEngineError.nothingToResume(job).code)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .ended)
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .settled(.succeeded))
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .ended)
    #expect(await refusal { _ = try await engine.resumeHere(job: job) } == JobEngineError.nothingToResume(job).code)
    let missing = try NovelJobRequest(kind: .generate, novel: world.novel, chapter: 9, fingerprint: "f:9").key(run: 1).ref
    #expect(await refusal { _ = try await engine.interrupt(job: missing, releasingLease: false) } == JobEngineError.jobNotFound(missing).code)
    #expect(await refusal { _ = try await engine.resumeHere(job: missing) } == JobEngineError.jobNotFound(missing).code)
  }

  @Test(arguments: [false, true])
  func shouldRefuseToResumeBesideALiveAttemptThatWouldNotStandDown(byHand: Bool) async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let first = try await engine.run(job: job)
    try await world.waitForRequests(2)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .interrupted(first.attempt))
    #expect(await first.result == .interrupted)
    let other = JobWorld.replicas[1]
    let started = byHand ? world.clock.now.addingTimeInterval(1) : world.clock.now.addingTimeInterval(-10)
    let blocking = try AttemptID(UUID.v7(at: started))
    let start = AttemptStart(job: job, replica: other, started: LeaseInstant(date: started, source: .device), byHand: byHand, pinned: .null)
    _ = try await world.store.write { transaction in try AttemptRecords.start(blocking, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    world.clock.advance(1)
    #expect(await refusal { _ = try await engine.resumeHere(job: job) } == JobEngineError.runningElsewhere(blocking, other).code)
    #expect(try await engine.interruptedRuns().map(\.attempt) == [first.attempt], "a refused resume keeps the checkpoint")
    #expect(world.provider.requests.count == 2)
    world.clock.advance(400)
    world.provider.enqueue(JobEngineWorld.reply())
    let resumed = try await engine.resumeHere(job: job)
    #expect(resumed.attempt == first.attempt, "once that lease lapsed the resume goes on")
    #expect(await resumed.result == .settled(.succeeded))
  }

  @Test func shouldKeepTheResumedHandleWhenTheInterruptedRunsResultIsReadLate() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.frozen, JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let first = try await engine.run(job: job)
    try await world.waitForRequests(2)
    #expect(try await engine.interrupt(job: job, releasingLease: false) == .interrupted(first.attempt))
    let resumed = try await engine.resumeHere(job: job)
    try await world.waitForRequests(3)
    #expect(await first.result == .interrupted)
    let again = try await engine.runHere(job: job)
    #expect(again.attempt == resumed.attempt && again.token == resumed.token, "Run here answers the resumed run, not a new start")
    #expect(try await engine.cancel(job: job) == .requested)
    #expect(await resumed.result == .settled(.cancelled))
  }

  @Test func shouldResumeHereBesideAnotherDevicesLiveLease() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let first = try await engine.run(job: job)
    try await world.waitForRequests(2)
    #expect(try await engine.interrupt(job: job, releasingLease: true) == .interrupted(first.attempt))
    #expect(await first.result == .interrupted)
    world.clock.advance(1)
    let other = JobWorld.replicas[1]
    let later = try AttemptID(UUID.v7(at: world.clock.now))
    let start = AttemptStart(job: job, replica: other, started: world.clock.instant, byHand: false, pinned: .null)
    _ = try await world.store.write { transaction in try AttemptRecords.start(later, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    #expect(await refusal { _ = try await engine.runHere(job: job) } == JobEngineError.runningElsewhere(later, other).code)
    world.provider.enqueue(JobEngineWorld.reply())
    let resumed = try await engine.resumeHere(job: job)
    #expect(resumed.attempt == first.attempt)
    #expect(await resumed.result == .settled(.succeeded))
    #expect(try await world.status(job) == .succeeded(first.attempt))
  }

  @Test func shouldSendNoModelCallOnceInterrupted() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply()]))
    let latch = StepLatch()
    let engine = try world.engine(catalog: { _ in .ready(JobEngineWorld.latched(latch)) })
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await engineEventually("the step is held") { latch.isReached }
    let interruption = Task { try await engine.interrupt(job: job, releasingLease: false) }
    try await engineEventually("the run was stopped") { latch.isStopping }
    latch.open()
    #expect(try await interruption.value == .interrupted(handle.attempt))
    #expect(await handle.result == .interrupted)
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.ledgerIDs().isEmpty)
    #expect(try await world.attempt(handle.attempt).calls.isEmpty)
    try await world.expectOutputsWrittenOnce(job, steps: [])
    #expect(try await engine.interruptedRuns().map(\.step) == [AttemptStep(name: "draft", index: 0)])
  }

  @Test func shouldRequireConsentBeforeResumingHere() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.frozen]))
    let engine = try world.engine()
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await world.waitForRequests(1)
    #expect(try await engine.interrupt(job: job, releasingLease: false) == .interrupted(handle.attempt))
    #expect(await handle.result == .interrupted)
    try await world.store.write { transaction in
      for host in ["api.example.com", "router.example.com"] {
        try AIConsent.decide(
          .revoked, provider: host, dataClass: CompactionWorld.consent.dataClass, summary: CompactionWorld.consent.disclosure, atMillis: 2, in: &transaction)
      }
    }
    do {
      _ = try await engine.resumeHere(job: job)
      Issue.record("a resume started without consent")
    } catch {
      #expect(error.code == "routing.consent_required")
    }
    #expect(try await engine.interruptedRuns().map(\.attempt) == [handle.attempt])
  }
}

@Suite("Job engine: run progress", TestTimeLimit.standard)
struct JobRunProgressTests {
  private static func current(_ board: RunProgressBoard, _ attempt: AttemptID) async -> JobRunProgress? {
    var values = board.observe(attempt).makeAsyncIterator()
    return await values.next()
  }

  private static func expect(
    _ progress: JobRunProgress?, step: String, done: Int, total: Int, received: Int, expected: Int, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    #expect(progress?.step?.name == step && progress?.stepsDone == done && progress?.stepsTotal == total, sourceLocation: sourceLocation)
    #expect(progress?.tokensReceived == received && progress?.tokensExpected == expected, sourceLocation: sourceLocation)
  }

  @Test func shouldCountTokensSoReceivedOnlyGrowsThroughARepairAndARetry() async throws {
    let board = RunProgressBoard()
    let attempt = try AttemptID(UUID.v7(at: EngineClock.epoch))
    let token = board.begin(attempt)
    let observe = board.observer(for: attempt)
    let (draft, repair, polish) = (UUID(), UUID(), UUID())
    board.enter(attempt, step: AttemptStep(name: "draft", index: 0), outlook: StepOutlook(stepsAhead: 1, ownTokens: 100, aheadTokens: 50))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 0, expected: 150)
    observe(.started(call: draft, maxOutputTokens: 100))
    observe(.delta(call: draft, estimatedTokens: 30))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 30, expected: 150)
    observe(.finished(call: draft, outputTokens: 40, outcome: .completed))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 40, expected: 90)
    observe(.started(call: repair, maxOutputTokens: 100))
    observe(.delta(call: repair, estimatedTokens: 10))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 50, expected: 190)
    observe(.finished(call: repair, outputTokens: 10, outcome: .failed))
    observe(.started(call: repair, maxOutputTokens: 100))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 50, expected: 200)
    observe(.delta(call: repair, estimatedTokens: 5))
    observe(.finished(call: repair, outputTokens: 8, outcome: .completed))
    Self.expect(await Self.current(board, attempt), step: "draft", done: 0, total: 2, received: 58, expected: 108)

    board.enter(attempt, step: AttemptStep(name: "polish", index: 1), outlook: StepOutlook(stepsAhead: 0, ownTokens: 50, aheadTokens: 0))
    Self.expect(await Self.current(board, attempt), step: "polish", done: 1, total: 2, received: 58, expected: 108)
    observe(.started(call: polish, maxOutputTokens: 50))
    observe(.delta(call: polish, estimatedTokens: 20))
    observe(.finished(call: polish, outputTokens: 15, outcome: .completed))
    Self.expect(await Self.current(board, attempt), step: "polish", done: 1, total: 2, received: 78, expected: 78)

    board.enter(attempt, step: AttemptStep(name: "repair", index: 2), outlook: StepOutlook(stepsAhead: 3, ownTokens: 0, aheadTokens: 0))
    board.enter(attempt, step: AttemptStep(name: "finish", index: 3), outlook: StepOutlook(stepsAhead: 0, ownTokens: 0, aheadTokens: 0))
    Self.expect(await Self.current(board, attempt), step: "finish", done: 3, total: 6, received: 78, expected: 78)

    board.end(attempt, token: token)
    #expect(await Self.current(board, attempt) == nil)
  }

  @Test func shouldFinishTheObserversOfARunWhenItsAttemptIsTrackedAgain() async throws {
    let board = RunProgressBoard()
    let attempt = try AttemptID(UUID.v7(at: EngineClock.epoch))
    let first = board.begin(attempt)
    board.enter(attempt, step: AttemptStep(name: "polish", index: 1), outlook: StepOutlook(stepsAhead: 0, ownTokens: 10, aheadTokens: 0))
    var stale = board.observe(attempt).makeAsyncIterator()
    #expect(await stale.next()?.step?.name == "polish")
    let second = board.begin(attempt)
    #expect(await stale.next() == nil)
    board.end(attempt, token: first)
    #expect(await Self.current(board, attempt)?.step?.name == "polish", "the earlier run's end leaves the resumed run's progress")
    board.end(attempt, token: second)
    #expect(await Self.current(board, attempt) == nil)
  }

  @Test(arguments: NovelJobKind.allCases)
  func shouldChartEveryPipelinesUsualCourseOverItsOwnSteps(_ kind: NovelJobKind) throws {
    guard case .ready(let pipeline) = PipelineCatalog.definition(for: kind) else { return }
    let course = try #require(pipeline.course)
    let steps = Set(pipeline.steps.keys)
    #expect(course.order.first == pipeline.first)
    #expect(Set(course.order + Array(course.tasks.keys) + Array(course.rejoins.keys) + Array(course.rejoins.values)).isSubset(of: steps))
    #expect(Set(course.order).count == course.order.count)
  }

  @Test func shouldReportARunsStepsAndTokensUntilItEnds() async throws {
    let invalid = ScriptedModelProvider.reply("not json")
    let retried: [ScriptedModelProvider.Step] =
      [.event(.retrying(attempt: 1, delay: .zero, cause: .overloaded(retryAfter: nil), requestID: nil, generationID: nil))] + JobEngineWorld.reply()
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [invalid, JobEngineWorld.reply(), retried]))
    let latch = StepLatch()
    let engine = try world.engine(catalog: { _ in .ready(JobEngineWorld.latched(latch)) })
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    try await engineEventually("the step is held") { latch.isReached }
    var values = engine.observeRun(attempt: handle.attempt).makeAsyncIterator()
    var seen = [try #require(await values.next())]
    latch.open()
    while let progress = await values.next() { seen.append(progress) }
    #expect(await handle.result == .settled(.succeeded))
    let cap = try world.router { _ in nil }.route(task: .writing, pace: .steady).maxOutputTokens
    let first = try #require(seen.first)
    #expect(first.step == AttemptStep(name: "draft", index: 0) && first.stepsTotal == 2 && first.tokensExpected == 2 * cap)
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.tokensReceived <= $1.tokensReceived && $0.stepsTotal <= $1.stepsTotal && $0.stepsDone <= $1.stepsDone })
    let last = try #require(seen.last)
    #expect(last.step == AttemptStep(name: "polish", index: 1) && last.stepsDone == 1 && last.stepsTotal == 2)
    #expect(last.tokensReceived == 15 && last.tokensExpected == 15, "three completed calls of five reported tokens each")
    #expect(world.provider.requests.count == 3)
    var after = engine.observeRun(attempt: handle.attempt).makeAsyncIterator()
    #expect(await after.next() == nil)
  }
}
