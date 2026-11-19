import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowJobs

@Suite("AttemptRunner", TestTimeLimit.quick)
struct AttemptRunnerTests {
  @Test func shouldRunEveryStepCommittingEachOutputOnceAndSucceedWithTheLastOne() async throws {
    let world = try await JobWorld()
    let model = FakeModel()
    let handle = try await world.start(world.runner(), model)
    #expect(await handle.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce()
    let attempt = try await JobFixture.attempt(handle.attempt, in: world.store)
    #expect(attempt.outcome == .succeeded && attempt.error == nil)
    #expect(attempt.calls.count == 3 && model.calls == 3)
    #expect(attempt.step == AttemptStep(name: "title", index: 2))
    #expect(attempt.start.pinned == ["plan": "p1"] && attempt.start.byHand == false && attempt.start.started.source == .device)
    #expect(try await world.status() == .succeeded(handle.attempt))
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldFailTheAttemptWithTheStepsErrorAndKeepWhatEarlierStepsSaved() async throws {
    let world = try await JobWorld()
    let model = FakeModel()
    var steps = world.pipeline(model).steps
    steps["expand"] = FailingStep()
    let handle = try await world.runner().start(job: world.key.ref, pipeline: AttemptPipeline(first: "draft", steps: steps), input: ["text": "seed"])
    let failure = AttemptFailure(code: "test.refused", message: "The step refused.")
    #expect(await handle.result == .settled(.failed(failure)))
    try await world.expectOutputsWrittenOnce(["draft"])
    #expect(try await world.status() == .failed(handle.attempt, failure))
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldFailAStepNamingANextStepThePipelineDoesNotHaveWithoutCommittingIt() async throws {
    let world = try await JobWorld()
    var steps = world.pipeline(FakeModel()).steps
    steps["draft"] = FakeStep(name: "draft", next: "polish", store: world.store, model: FakeModel())
    let handle = try await world.runner().start(job: world.key.ref, pipeline: AttemptPipeline(first: "draft", steps: steps), input: ["text": "seed"])
    #expect(await handle.result == .settled(.failed(AttemptFailure(JobRunError.unknownStep("polish")))))
    #expect(try await JobFixture.outputs(in: world.store).isEmpty)
  }

  @Test func shouldAbortTheInFlightCallOnCancelAndSettleCancelled() async throws {
    let world = try await JobWorld()
    let model = FakeModel(freezing: [1])
    let runner = world.runner()
    let handle = try await world.start(runner, model)
    try await model.waitFrozen()
    #expect(try await runner.cancel(job: world.key.ref) == .requested)
    #expect(await handle.result == .settled(.cancelled))
    try await world.expectOutputsWrittenOnce(["draft"])
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).calls.count == 2)
    #expect(try await world.status() == .cancelled)
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
    #expect(runner.runningAttempts.isEmpty)
  }

  @Test func shouldStopWhenACancelFromAnotherDeviceArrives() async throws {
    let world = try await JobWorld()
    let other = try JobFixture.open()
    try await JobFixture.exchange([world.store, other])
    let model = FakeModel(freezing: [0])
    let handle = try await world.start(world.runner(), model)
    try await model.waitFrozen()
    _ = try await other.write { transaction in try JobRecords.cancel(try JobFixture.key().ref, in: &transaction) }
    _ = try await world.store.applyRemote(try await other.pendingChanges(limit: Int.max).map(\.line))
    #expect(await handle.result == .settled(.cancelled))
    #expect(try await JobFixture.outputs(in: world.store).isEmpty)
  }

  @Test func shouldStandDownWhenAnotherDevicesAttemptSucceeds() async throws {
    let world = try await JobWorld()
    let other = try JobFixture.open()
    try await JobFixture.exchange([world.store, other])
    let model = FakeModel(freezing: [1])
    let handle = try await world.start(world.runner(), model)
    try await model.waitFrozen()
    let id = try JobFixture.attemptID(30, 5)
    let start = JobFixture.start(world.key, replica: other.replica, at: 30)
    let writer = other.replica
    _ = try await other.write { transaction in
      _ = try AttemptRecords.start(id, start, step: nil, in: &transaction)
      try AttemptRecords.update(id, AttemptUpdate(settlement: .succeeded), by: writer, in: &transaction)
    }
    _ = try await world.store.applyRemote(try await other.pendingChanges(limit: Int.max).map(\.line))
    #expect(await handle.result == .settled(.stoodDown))
    #expect(try await world.status() == .succeeded(id))
  }

  @Test func shouldStandDownForAnEarlierLiveAttemptThatArrivesWhileItRuns() async throws {
    let world = try await JobWorld()
    let other = try JobFixture.open()
    try await JobFixture.exchange([world.store, other])
    let model = FakeModel(freezing: [1])
    let handle = try await world.start(world.runner(), model)
    try await model.waitFrozen()
    let id = try JobFixture.attemptID(-10, 5)
    let start = JobFixture.start(world.key, replica: other.replica, at: -10)
    _ = try await other.write { transaction in try AttemptRecords.start(id, start, step: nil, in: &transaction) }
    _ = try await world.store.applyRemote(try await other.pendingChanges(limit: Int.max).map(\.line))
    #expect(await handle.result == .settled(.stoodDown))
    try await world.expectOutputsWrittenOnce(["draft"])
    #expect(try await world.status() == .running(id))
  }

  @Test func shouldRenewTheLeaseOnEveryHeartbeatWhileACallIsInFlight() async throws {
    let world = try await JobWorld()
    let model = FakeModel(freezing: [0])
    let ticker = Ticker()
    let runner = world.runner(ticker: ticker)
    let handle = try await world.start(runner, model)
    try await model.waitFrozen()
    let started = try await JobFixture.attempt(handle.attempt, in: world.store).lease
    for beat in 1...2 {
      world.clock.advance(120)
      ticker.tick()
      let renewed = LeaseInstant(date: world.clock.now, source: .device).millis
      try await eventually("heartbeat \(beat) renewed the lease") { try await JobFixture.attempt(handle.attempt, in: world.store).lease?.renewed == renewed }
    }
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).lease?.expires == (started?.expires ?? 0) + 240_000)
    _ = try await runner.cancel(job: world.key.ref)
    #expect(await handle.result == .settled(.cancelled))
  }

  @Test func shouldRefuseToStartAJobThatIsNotHereSucceededOrCancelled() async throws {
    let world = try await JobWorld()
    let runner = world.runner()
    let missing = try JobFixture.key(run: 9).ref
    await #expect(throws: JobRunError.self) { try await runner.start(job: missing, pipeline: world.pipeline(FakeModel()), input: ["text": "seed"]) }
    let done = try await world.start(runner, FakeModel())
    #expect(await done.result == .settled(.succeeded))
    await expectRefusal(.jobSucceeded(world.key.ref)) { try await world.start(runner, FakeModel(), byHand: true) }

    let cancelled = try await JobWorld()
    _ = try await cancelled.runner().cancel(job: cancelled.key.ref)
    await expectRefusal(.jobCancelled(cancelled.key.ref)) { try await cancelled.start(cancelled.runner(), FakeModel(), byHand: true) }
    #expect(try await JobFixture.localRuns(in: cancelled.store).isEmpty)
  }

  @Test func shouldRefuseASecondAutomaticAttemptWhileOneIsLiveButStartOneByHand() async throws {
    let world = try await JobWorld()
    let model = FakeModel(freezing: [0])
    let first = world.runner()
    let handle = try await world.start(first, model)
    world.clock.advance(1)
    await expectRefusal(.alreadyRunningHere(handle.attempt)) { try await world.start(first, model) }
    await expectRefusal(.alreadyRunningHere(handle.attempt)) { try await world.start(world.runner(), model, byHand: true) }
    let otherClock = DeviceClock()
    otherClock.advance(1)
    let other = try JobFixture.open(clock: otherClock)
    try await JobFixture.exchange([world.store, other])
    let otherModel = FakeModel(freezing: [0])
    let otherRunner = world.runner(store: other, clock: otherClock)
    let start = { (byHand: Bool) in
      try await otherRunner.start(job: world.key.ref, pipeline: world.pipeline(otherModel, in: other), input: ["text": "seed"], byHand: byHand)
    }
    await expectRefusal(.anotherAttemptLive(handle.attempt)) { try await start(false) }
    let manual = try await start(true)
    try await otherModel.waitFrozen()
    _ = try await first.cancel(job: world.key.ref)
    #expect(await handle.result == .settled(.cancelled))
    _ = try await other.applyRemote(try await world.store.pendingChanges(limit: Int.max).map(\.line))
    #expect(await manual.result == .settled(.cancelled))
  }

  @Test func shouldRenewALeaseStampedByAFastClockOnceTheClockIsCorrected() async throws {
    let world = try await JobWorld()
    let ticker = Ticker()
    world.clock.advance(3600)
    let model = FakeModel(freezing: [0])
    let runner = world.runner(ticker: ticker)
    let handle = try await world.start(runner, model)
    try await model.waitFrozen()
    world.clock.advance(-3600)
    #expect(try await world.status() == .queued)
    ticker.tick()
    let corrected = LeaseInstant(date: world.clock.now, source: .device)
    try await eventually("the heartbeat rewrote the lease") { try await JobFixture.attempt(handle.attempt, in: world.store).lease?.renewed == corrected.millis }
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).isLive(at: corrected))
    #expect(try await world.status() == .running(handle.attempt))
    _ = try await runner.cancel(job: world.key.ref)
    #expect(await handle.result == .settled(.cancelled))
  }

  @Test func shouldRefuseAPipelineWhoseFirstStepIsMissing() async throws {
    let world = try await JobWorld()
    await expectRefusal(.unknownStep("plan")) {
      try await world.runner().start(job: world.key.ref, pipeline: AttemptPipeline(first: "plan", steps: [:]), input: .null)
    }
  }

  @Test func shouldLeaveAnAttemptWhoseKindNoPipelineKnowsAndFailOneWithoutACheckpoint() async throws {
    let world = try await JobWorld()
    let first = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await first.result == .interrupted)
    #expect(try await world.runner().resumeInterrupted { _ in nil }.isEmpty)
    #expect(try await JobFixture.localRuns(in: world.store).map(\.attempt) == [first.attempt])
    try await world.store.write { transaction in try transaction.database.execute(sql: "DELETE FROM jobs_local_checkpoint") }
    #expect(try await world.runner().resumeInterrupted { _ in world.pipeline(FakeModel()) }.isEmpty)
    let failed = try await JobFixture.attempt(first.attempt, in: world.store)
    #expect(failed.outcome == .failed && failed.error?.code == "job_run.checkpoint_unreadable")
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldDropARunThisReplicaCanNoLongerWriteAfterItIsReminted() async throws {
    let world = try await JobWorld()
    let first = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await first.result == .interrupted)
    try await world.store.remint(to: JobFixture.replica(42), mode: .keepState)
    #expect(try await world.runner().resumeInterrupted { _ in world.pipeline(FakeModel()) }.isEmpty)
    let tables = try await world.store.read { transaction in try JobsLocal.run(first.attempt, in: transaction.database) }
    #expect(tables == nil)
    #expect(try await JobFixture.attempt(first.attempt, in: world.store).outcome == .running)
  }

  private func expectRefusal(_ expected: JobRunError, _ body: () async throws -> AttemptHandle) async {
    do {
      _ = try await body()
      Issue.record("expected \(expected.code)")
    } catch let error as JobRunError {
      #expect(error.code == expected.code && error.errorDescription == expected.errorDescription)
    } catch {
      Issue.record("expected \(expected.code), not \(error)")
    }
  }
}

private struct FailingStep: PipelineStep {
  struct Refusal: ShadowError {
    var code: String { "test.refused" }
    var errorDescription: String? { "The step refused." }
  }

  func run(_ input: JSONValue, in context: AttemptStepContext) async throws -> AttemptStepOutput {
    throw Refusal()
  }
}
