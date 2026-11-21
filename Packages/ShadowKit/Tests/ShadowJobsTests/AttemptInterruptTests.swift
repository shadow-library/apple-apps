import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowJobs

@Suite("AttemptRunner interrupt", TestTimeLimit.quick)
struct AttemptInterruptTests {
  @Test func shouldWriteNothingAfterAnInterruptKeepTheCheckpointAndResumeToTheOutputsOfAnUninterruptedRun() async throws {
    let world = try await JobWorld()
    let ticker = Ticker()
    let runner = world.runner(ticker: ticker)
    let stubborn = StubbornStep(name: "expand", next: "title", store: world.store)
    let handle = try await runner.start(job: world.key.ref, pipeline: world.pipeline(FakeModel(), replacing: "expand", with: stubborn), input: ["text": "seed"])
    try await eventually("the stubborn step runs") { stubborn.hasEntered }
    let before = try await world.store.pendingChanges(limit: Int.max).count
    let attemptBefore = try await JobFixture.attempt(handle.attempt, in: world.store)

    let returned = Gate()
    let interruption = Task {
      defer { returned.open() }
      return try await runner.interrupt(handle.attempt, releasingLease: false)
    }
    try await eventually("the step sees the interrupt") { stubborn.hasSeenStop }
    world.clock.advance(120)
    ticker.tick()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!returned.isOpen)
    stubborn.carryOn()
    #expect(try await interruption.value == .interrupted)
    #expect(runner.runningAttempts.isEmpty)
    #expect(await handle.result == .interrupted)

    #expect(try await world.store.pendingChanges(limit: Int.max).count == before)
    #expect(stubborn.refusal == JobRecordError.attemptInterrupted(handle.attempt.ref).code)
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store) == attemptBefore)
    let checkpoint = LocalCheckpoint(attempt: handle.attempt, index: 1, next: "expand", state: ["text": "seed>draft"])
    #expect(try await world.store.read { transaction in try JobsLocal.checkpoint(handle.attempt, in: transaction.database) } == checkpoint)
    let held = InterruptedRun(attempt: handle.attempt, job: world.key.ref, step: AttemptStep(name: "expand", index: 1), checkpoint: checkpoint)
    #expect(try await runner.interruptedRuns() == [held])

    let resumed = try #require(try await runner.resume(handle.attempt) { _ in world.pipeline(FakeModel()) })
    #expect(await resumed.result == .settled(.succeeded))
    let uninterrupted = try await JobWorld()
    #expect(await (try await uninterrupted.start(uninterrupted.runner(), FakeModel())).result == .settled(.succeeded))
    #expect(try await JobFixture.outputs(in: world.store) == JobFixture.outputs(in: uninterrupted.store))
    try await world.expectOutputsWrittenOnce()
    #expect(try await runner.interruptedRuns().isEmpty)
  }

  @Test func shouldKeepAStepCommitTheInterruptRacesAndReleaseTheLeaseAfterIt() async throws {
    let world = try await JobWorld()
    let runner = world.runner()
    let racing = RacingStep(name: "expand", next: "title", runner: runner)
    let handle = try await runner.start(job: world.key.ref, pipeline: world.pipeline(FakeModel(), replacing: racing.name, with: racing), input: ["text": "seed"])
    #expect(await handle.result == .interrupted)
    #expect(try await racing.interruption() == .interrupted)

    try await world.expectOutputsWrittenOnce(["draft", "expand"])
    let checkpoint = try await world.store.read { transaction in try JobsLocal.checkpoint(handle.attempt, in: transaction.database) }
    #expect(checkpoint == LocalCheckpoint(attempt: handle.attempt, index: 2, next: "title", state: ["text": "seed>draft>expand"]))
    let attempt = try await JobFixture.attempt(handle.attempt, in: world.store)
    let now = LeaseInstant(date: world.clock.now, source: .device)
    #expect(attempt.step == AttemptStep(name: "title", index: 2))
    #expect(attempt.lease == .released(at: now) && !attempt.isLive(at: now))

    let resumed = try await runner.resumeInterrupted { _ in world.pipeline(FakeModel()) }
    #expect(resumed.map(\.attempt) == [handle.attempt])
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }
    try await world.expectOutputsWrittenOnce()
  }

  /// The run reports what a crash after the final commit reports, and the interrupt tells that the attempt is no longer here to resume.
  @Test func shouldEndWithoutALeaseWriteWhenTheInterruptRacesTheFinalCommit() async throws {
    let world = try await JobWorld()
    let runner = world.runner()
    let racing = RacingStep(name: "title", next: nil, runner: runner)
    let handle = try await runner.start(job: world.key.ref, pipeline: world.pipeline(FakeModel(), replacing: racing.name, with: racing), input: ["text": "seed"])
    #expect(await handle.result == .interrupted)
    #expect(try await racing.interruption() == .ended)
    let attempt = try await JobFixture.attempt(handle.attempt, in: world.store)
    #expect(attempt.outcome == .succeeded && attempt.lease?.renewed == JobFixture.epoch && attempt.lease?.expires != JobFixture.epoch)
    try await world.expectOutputsWrittenOnce()
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldReleaseTheReservationBeforeReturningWhenTheInterruptLandsInsideTheResumeTransaction() async throws {
    let world = try await JobWorld()
    let other = try JobFixture.key(target: "chapter:4")
    _ = try await world.store.write { transaction in try JobRecords.request(JobFixture.request(other, replica: world.store.replica), in: &transaction) }
    let first = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await first.result == .interrupted)
    world.clock.advance(1)
    let second = try await world.runner(.once(at: .afterCommit(step: 0))).start(job: other.ref, pipeline: world.pipeline(FakeModel()), input: ["text": "seed"])
    #expect(await second.result == .interrupted)

    let heartbeat = Gate()
    let timing = AttemptRunner.Timing(heartbeat: LeaseTerms.heartbeat) { _ in
      await heartbeat.wait()
      try await Task.sleep(for: .seconds(3600))
    }
    let runner = AttemptRunner(store: world.store, clock: LeaseClock(trusted: nil, device: world.clock.function), timing: timing, faults: .none)
    let returned = Gate()
    let interruption = Mutex<Task<AttemptInterruption, any Error>?>(nil)
    let resumed = try await runner.resumeInterrupted(
      where: { run in
        guard run.attempt == second.attempt else { return true }
        interruption.withLock {
          $0 = Task {
            defer { returned.open() }
            return try await runner.interrupt(first.attempt, releasingLease: true)
          }
        }
        let deadline = ContinuousClock.now + .seconds(30)
        while runner.control(of: first.attempt)?.isCrashed != true, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.002) }
        return true
      }, pipeline: { _ in world.pipeline(FakeModel()) })
    let task = try #require(interruption.withLock { $0 })
    try await Task.sleep(for: .milliseconds(50))
    #expect(!returned.isOpen && runner.runningAttempts.contains(first.attempt))
    heartbeat.open()
    #expect(try await task.value == .interrupted)
    #expect(!runner.runningAttempts.contains(first.attempt))

    #expect(Set(resumed.map(\.attempt)) == [first.attempt, second.attempt])
    for run in resumed { #expect(await run.result == (run.attempt == first.attempt ? .interrupted : .settled(.succeeded))) }
    let now = LeaseInstant(date: world.clock.now, source: .device)
    #expect(try await JobFixture.attempt(first.attempt, in: world.store).lease == .released(at: now))
    #expect(try await runner.interruptedRuns().map(\.attempt) == [first.attempt])
    let again = try #require(try await world.runner().resume(first.attempt) { _ in world.pipeline(FakeModel()) })
    #expect(await again.result == .settled(.succeeded))
  }

  @Test func shouldAnswerSettlingForARunWithAStopMarkAndLeaveItToSettleStopped() async throws {
    let world = try await JobWorld()
    let runner = world.runner()
    let stubborn = StubbornStep(name: "expand", next: "title", store: world.store)
    let handle = try await runner.start(job: world.key.ref, pipeline: world.pipeline(FakeModel(), replacing: "expand", with: stubborn), input: ["text": "seed"])
    try await eventually("the stubborn step runs") { stubborn.hasEntered }
    _ = try await runner.cancel(job: world.key.ref)
    try await eventually("the step sees the cancel") { stubborn.hasSeenStop }
    let interruption = Task { try await runner.interrupt(handle.attempt, releasingLease: true) }
    stubborn.carryOn()
    #expect(try await interruption.value == .settling)
    #expect(await handle.result == .interrupted)
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).outcome == .running)
    #expect(try await runner.interruptedRuns().isEmpty)
    #expect(try await runner.interrupt(handle.attempt, releasingLease: true) == .settling)
    #expect(try await runner.settleStopped() == [handle.attempt])
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).outcome == .cancelled)
    #expect(try await runner.interrupt(handle.attempt, releasingLease: true) == .ended)
  }

  @Test func shouldForgetAnUnmarkedRunWhoseJobIsGoneWhenSettlingStopMarks() async throws {
    let world = try await JobWorld()
    let crashed = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await crashed.result == .interrupted)
    _ = try await world.store.write { transaction in try transaction.purge(world.key.ref) }
    let runner = world.runner()
    #expect(try await runner.interruptedRuns().isEmpty)
    #expect(try await runner.settleStopped().isEmpty)
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldAnswerEndedForAFinishedRunAndReleaseTheLeaseOfOneHeldHereButNotRunning() async throws {
    let world = try await JobWorld()
    let done = try await world.start(world.runner(), FakeModel())
    #expect(await done.result == .settled(.succeeded))
    let pending = try await world.store.pendingChanges(limit: Int.max).count
    #expect(try await world.runner().interrupt(done.attempt, releasingLease: true) == .ended)
    #expect(try await world.store.pendingChanges(limit: Int.max).count == pending)

    let other = try JobFixture.key(target: "chapter:4")
    _ = try await world.store.write { transaction in try JobRecords.request(JobFixture.request(other, replica: world.store.replica), in: &transaction) }
    let crashed = try await world.runner(.once(at: .afterCommit(step: 0))).start(job: other.ref, pipeline: world.pipeline(FakeModel()), input: ["text": "seed"])
    #expect(await crashed.result == .interrupted)
    world.clock.advance(30)
    let now = LeaseInstant(date: world.clock.now, source: .device)
    #expect(try await JobFixture.attempt(crashed.attempt, in: world.store).isLive(at: now))
    let runner = world.runner()
    #expect(try await runner.interrupt(crashed.attempt, releasingLease: true) == .notRunning)
    #expect(try await JobFixture.attempt(crashed.attempt, in: world.store).lease == .released(at: now))
    let released = try await world.store.pendingChanges(limit: Int.max).count
    #expect(try await runner.interrupt(crashed.attempt, releasingLease: true) == .notRunning)
    #expect(try await world.store.pendingChanges(limit: Int.max).count == released)
    #expect(try await runner.interruptedRuns().map(\.attempt) == [crashed.attempt])
  }

  @Test(arguments: [true, false])
  func shouldLetAnotherReplicasAutomaticAttemptProceedOnlyOnceTheLeaseIsReleased(_ releasing: Bool) async throws {
    let phone = try await JobWorld()
    let mac = try Replica(of: phone, aheadBy: 10)
    let model = FakeModel(freezing: [0])
    let runner = phone.runner()
    let first = try await phone.start(runner, model)
    try await model.waitFrozen()
    try await JobFixture.exchange([phone.store, mac.store])
    #expect(try await mac.verdict(for: phone) == .standDown(.outranked(first.attempt)))

    #expect(try await runner.interrupt(first.attempt, releasingLease: releasing) == .interrupted)
    #expect(await first.result == .interrupted)
    try await JobFixture.exchange([phone.store, mac.store])

    guard releasing else {
      #expect(try await mac.verdict(for: phone) == .standDown(.outranked(first.attempt)))
      await #expect(throws: JobRunError.self) { try await mac.start(phone, FakeModel()) }
      return
    }
    #expect(try await mac.verdict(for: phone) == .proceed)
    let second = try await mac.start(phone, FakeModel())
    #expect(await second.result == .settled(.succeeded))
    #expect(JobStatus(try await JobFixture.snapshot(phone.key.ref, in: mac.store), at: mac.now) == .succeeded(second.attempt))
  }

  @Test func shouldStandTheOtherReplicasAutomaticAttemptDownWhenAByHandAttemptResumes() async throws {
    let phone = try await JobWorld()
    let mac = try Replica(of: phone, aheadBy: 10)
    let model = FakeModel(freezing: [0])
    let runner = phone.runner()
    let byHand = try await phone.start(runner, model, byHand: true)
    try await model.waitFrozen()
    #expect(try await runner.interrupt(byHand.attempt, releasingLease: true) == .interrupted)
    try await JobFixture.exchange([phone.store, mac.store])

    let macModel = FakeModel(freezing: [0])
    let automatic = try await mac.start(phone, macModel)
    try await macModel.waitFrozen()
    let resumedModel = FakeModel(freezing: [0])
    let resumed = try #require(try await runner.resume(byHand.attempt) { _ in phone.pipeline(resumedModel) })
    try await resumedModel.waitFrozen()
    try await JobFixture.exchange([phone.store, mac.store])

    #expect(await automatic.result == .settled(.stoodDown))
    #expect(JobStatus(try await JobFixture.snapshot(phone.key.ref, in: mac.store), at: mac.now) == .running(byHand.attempt))
    #expect(try await JobFixture.outputs(in: mac.store).isEmpty)
    _ = try await runner.cancel(job: phone.key.ref)
    #expect(await resumed.result == .settled(.cancelled))
  }

  @Test func shouldStandAResumedAttemptDownWhenAnotherReplicaFinishedTheJobWhileItWasInterrupted() async throws {
    let phone = try await JobWorld()
    let mac = try Replica(of: phone, aheadBy: 10)
    let model = FakeModel(freezing: [0])
    let runner = phone.runner()
    let first = try await phone.start(runner, model)
    try await model.waitFrozen()
    #expect(try await runner.interrupt(first.attempt, releasingLease: true) == .interrupted)
    try await JobFixture.exchange([phone.store, mac.store])
    let second = try await mac.start(phone, FakeModel())
    #expect(await second.result == .settled(.succeeded))
    try await JobFixture.exchange([phone.store, mac.store])

    let resumed = try #require(try await runner.resume(first.attempt) { _ in phone.pipeline(FakeModel()) })
    #expect(await resumed.result == .settled(.stoodDown))
    #expect(try await phone.status() == .succeeded(second.attempt))
    #expect(try await JobFixture.localRuns(in: phone.store).isEmpty)
  }

  @Test func shouldSettleStopMarksWithoutResumingAndListOnlyTheRunsThatCanResume() async throws {
    let world = try await JobWorld()
    let stoppedModel = FakeModel(freezing: [1])
    let stopping = world.runner(.once(at: .settling))
    let stopped = try await world.start(stopping, stoppedModel)
    try await stoppedModel.waitFrozen()
    _ = try await stopping.cancel(job: world.key.ref)
    #expect(await stopped.result == .interrupted)
    let other = try JobFixture.key(target: "chapter:4")
    _ = try await world.store.write { transaction in try JobRecords.request(JobFixture.request(other, replica: world.store.replica), in: &transaction) }
    let crashed = try await world.runner(.once(at: .afterCommit(step: 0))).start(job: other.ref, pipeline: world.pipeline(FakeModel()), input: ["text": "seed"])
    #expect(await crashed.result == .interrupted)

    let runner = world.runner()
    #expect(try await runner.interruptedRuns().map(\.attempt) == [crashed.attempt])
    #expect(try await runner.settleStopped() == [stopped.attempt])
    #expect(try await JobFixture.attempt(stopped.attempt, in: world.store).outcome == .cancelled)
    #expect(try await JobFixture.attempt(crashed.attempt, in: world.store).outcome == .running)
    #expect(try await JobFixture.localRuns(in: world.store).map(\.attempt) == [crashed.attempt])
    #expect(try await runner.settleStopped().isEmpty)
    #expect(try await runner.interruptedRuns().map(\.attempt) == [crashed.attempt])
  }

  @Test func shouldResumeOnlyTheRunsTheFilterTakesAndLeaveTheOthersUntouched() async throws {
    let world = try await JobWorld()
    let other = try JobFixture.key(target: "chapter:4")
    _ = try await world.store.write { transaction in try JobRecords.request(JobFixture.request(other, replica: world.store.replica), in: &transaction) }
    let left = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    let taken = try await world.runner(.once(at: .afterCommit(step: 1))).start(job: other.ref, pipeline: world.pipeline(FakeModel()), input: ["text": "seed"])
    #expect(await left.result == .interrupted)
    #expect(await taken.result == .interrupted)

    let runner = world.runner()
    let pending = try await world.store.pendingChanges(limit: Int.max).count
    #expect(try await runner.resumeInterrupted(where: { _ in false }, pipeline: { _ in world.pipeline(FakeModel()) }).isEmpty)
    #expect(try await world.store.pendingChanges(limit: Int.max).count == pending)
    let resumed = try await runner.resumeInterrupted(where: { $0.job == other.ref }, pipeline: { _ in world.pipeline(FakeModel()) })
    #expect(resumed.map(\.attempt) == [taken.attempt])
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }
    #expect(try await runner.interruptedRuns().map(\.attempt) == [left.attempt])
  }
}

/// Its wait ignores cancellation, as a step or heartbeat that does not cooperate would.
private final class Gate: Sendable {
  private struct State {
    var isOpen = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  var isOpen: Bool { state.withLock { $0.isOpen } }

  func open() {
    let waiters = state.withLock { state in
      state.isOpen = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let open = state.withLock { state in
        guard !state.isOpen else { return true }
        state.waiters.append(continuation)
        return false
      }
      if open { continuation.resume() }
    }
  }
}

/// A second device on the same job, its clock ahead of the first's so its attempts start later.
private struct Replica {
  let clock = DeviceClock()
  let store: VaultStore

  init(of world: JobWorld, aheadBy seconds: TimeInterval) throws {
    clock.advance(seconds)
    store = try JobFixture.open(clock: clock)
  }

  var now: LeaseInstant { LeaseInstant(date: clock.now, source: .device) }

  func start(_ world: JobWorld, _ model: FakeModel) async throws -> AttemptHandle {
    try await world.runner(store: store, clock: clock).start(job: world.key.ref, pipeline: world.pipeline(model, in: store), input: ["text": "seed"])
  }

  /// What an automatic attempt started here now would be told.
  func verdict(for world: JobWorld) async throws -> AttemptVerdict {
    let snapshot = try await JobFixture.snapshot(world.key.ref, in: store)
    let start = AttemptStart(job: world.key.ref, replica: store.replica, started: now, byHand: false, pinned: .null)
    let prospective = AttemptRecord(
      id: try AttemptID(UUID.v7(at: now.date)), start: start, lease: .granted(at: now), step: nil, calls: [], outcome: .running, error: nil)
    return AttemptVerdict(for: prospective, in: snapshot, at: now)
  }
}

/// Ignores cancellation: it waits for the interrupt, then for the test, then tries to open a call from a task the interrupt did not cancel and hands back
/// an output anyway.
private final class StubbornStep: PipelineStep, Sendable {
  private struct State {
    var entered = false
    var sawStop = false
    var carryOn = false
    var refusal: String?
  }

  let name: String
  let next: String?
  let store: VaultStore
  private let state = Mutex(State())

  init(name: String, next: String?, store: VaultStore) {
    self.name = name
    self.next = next
    self.store = store
  }

  var hasEntered: Bool { state.withLock { $0.entered } }
  var hasSeenStop: Bool { state.withLock { $0.sawStop } }
  var refusal: String? { state.withLock { $0.refusal } }

  func carryOn() {
    state.withLock { $0.carryOn = true }
  }

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    guard let text = input["text"]?.stringValue else { throw FixtureError(description: "the checkpoint holds no text") }
    state.withLock { $0.entered = true }
    while !context.isStopping { await pause() }
    state.withLock { $0.sawStop = true }
    while !state.withLock({ $0.carryOn }) { await pause() }
    let store = store
    let opening = Task { try await store.write { transaction in try context.recordCall(UUID.v7(), in: &transaction) } }
    do {
      try await opening.value
    } catch {
      state.withLock { $0.refusal = (JobRunError.unwrapped(error) as? JobRecordError)?.code }
    }
    let output = "\(text)>\(name)"
    let ref = FakeStep.output(job: context.job.ref, step: name)
    return AttemptStepOutput(state: ["text": .string(output)], next: next) { transaction in
      _ = try transaction.append(ref, item: ["step": .string(self.name), "text": .string(output)])
    }
  }

  private func pause() async {
    try? await Task.sleep(for: .milliseconds(2))
  }
}

/// Interrupts its own attempt from inside the transaction that commits its output, holding that transaction open until the interrupt has begun.
private final class RacingStep: PipelineStep, Sendable {
  let name: String
  let next: String?
  let runner: AttemptRunner
  private let started = Mutex<Task<AttemptInterruption, any Error>?>(nil)

  init(name: String, next: String?, runner: AttemptRunner) {
    self.name = name
    self.next = next
    self.runner = runner
  }

  func interruption() async throws -> AttemptInterruption {
    guard let task = started.withLock({ $0 }) else { throw FixtureError(description: "the step never committed") }
    return try await task.value
  }

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    guard let text = input["text"]?.stringValue else { throw FixtureError(description: "the checkpoint holds no text") }
    let output = "\(text)>\(name)"
    let ref = FakeStep.output(job: context.job.ref, step: name)
    let (runner, attempt) = (runner, context.attempt)
    return AttemptStepOutput(state: ["text": .string(output)], next: next) { transaction in
      self.started.withLock { $0 = Task { try await runner.interrupt(attempt, releasingLease: true) } }
      let deadline = ContinuousClock.now + .seconds(30)
      while !context.isStopping {
        guard ContinuousClock.now < deadline else { throw FixtureError(description: "the interrupt never began") }
        Thread.sleep(forTimeInterval: 0.002)
      }
      _ = try transaction.append(ref, item: ["step": .string(self.name), "text": .string(output)])
    }
  }
}

extension JobWorld {
  fileprivate func pipeline(_ model: FakeModel, replacing name: String, with step: any PipelineStep) -> AttemptPipeline {
    var steps = pipeline(model).steps
    steps[name] = step
    return AttemptPipeline(first: "draft", steps: steps)
  }
}
