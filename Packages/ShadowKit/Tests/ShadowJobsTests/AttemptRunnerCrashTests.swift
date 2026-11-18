import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import ShadowJobs

/// A run is killed at every boundary of a three-step pipeline and a new runner on the same store resumes it, as a relaunched app does: the attempt ends
/// with the outputs of an uninterrupted run, each written once, and a call cut off by the crash stays in the attempt's call ids.
@Suite("AttemptRunner crashes", .timeLimit(.minutes(1)))
struct AttemptRunnerCrashTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let point: AttemptRunner.Faults.Point
    /// Calls the attempt records over both runs: one more than the three steps when the crash cut a call off or lost a step's output.
    let calls: Int
    var heartbeat = false

    var testDescription: String { "\(point)" }
  }

  static let cases: [Case] =
    (0..<AttemptRunnerCrashTests.writes).map { Case(point: .committed(write: $0), calls: 3) }
    + (0..<3).flatMap { step in
      [Case(point: .call(step: step), calls: 4), Case(point: .beforeCommit(step: step), calls: 4), Case(point: .afterCommit(step: step), calls: 3)]
    }
    + [Case(point: .renewing, calls: 4, heartbeat: true), Case(point: .renewed, calls: 4, heartbeat: true)]

  /// The start and one commit per step: a step's output written apart from its checkpoint would add a write the matrix crashes after.
  static let writes = 4

  @Test func shouldWriteOnceToStartAndOncePerStepInAnUninterruptedRun() async throws {
    let world = try await JobWorld()
    let points = Mutex<[AttemptRunner.Faults.Point]>([])
    let faults = AttemptRunner.Faults { point in
      points.withLock { $0.append(point) }
      return false
    }
    #expect(await (try await world.start(world.runner(faults), FakeModel())).result == .settled(.succeeded))
    #expect(points.withLock { $0 }.filter { if case .committed = $0 { true } else { false } } == (0..<Self.writes).map { .committed(write: $0) })
  }

  @Test func shouldWriteNothingOnceTheAttemptCrashed() async throws {
    let world = try await JobWorld()
    let control = AttemptControl(job: world.key.ref)
    control.crash()
    let before = try await world.store.pendingChanges(limit: Int.max).count
    await #expect(throws: JobRunError.self) {
      try await world.runner().write(control) { transaction in try JobRecords.cancel(world.key.ref, in: &transaction) }
    }
    #expect(try await world.store.pendingChanges(limit: Int.max).count == before)
  }

  @Test func shouldRefuseAFreshStartWhileAnInterruptedRunOfTheJobIsHereAndResumeItInstead() async throws {
    let world = try await JobWorld()
    let interrupted = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await interrupted.result == .interrupted)
    world.clock.advance(400)
    #expect(try await world.status() == .queued)
    let runner = world.runner()
    do {
      _ = try await world.start(runner, FakeModel())
      Issue.record("a second attempt started beside the interrupted one")
    } catch let error as JobRunError {
      #expect(error.code == JobRunError.alreadyRunningHere(interrupted.attempt).code)
    }
    let resumed = try await runner.resumeInterrupted { _ in world.pipeline(FakeModel()) }
    #expect(resumed.map(\.attempt) == [interrupted.attempt])
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }
    try await world.expectOutputsWrittenOnce()
    #expect(try await world.status() == .succeeded(interrupted.attempt))
  }

  @Test func shouldStandDownAnInterruptedRunWhenAStartOfItsJobIsUnderWayHere() async throws {
    let world = try await JobWorld()
    let interrupted = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await interrupted.result == .interrupted)
    let runner = world.runner()
    let starting = try JobFixture.attemptID(1, 9)
    try runner.reserve(starting, AttemptControl(job: world.key.ref))
    #expect(try await runner.resumeInterrupted { _ in world.pipeline(FakeModel()) }.isEmpty)
    #expect(try await JobFixture.attempt(interrupted.attempt, in: world.store).outcome == .stoodDown)
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
    #expect(try await world.status() == .queued)
    runner.release(starting)
    world.clock.advance(1)
    let model = FakeModel(freezing: [0])
    let manual = try await world.start(runner, model, byHand: true)
    try await model.waitFrozen()
    #expect(try await world.status() == .running(manual.attempt))
    _ = try await runner.cancel(job: world.key.ref)
    #expect(await manual.result == .settled(.cancelled))
  }

  @Test(arguments: cases)
  func shouldResumeFromTheLastCheckpointWithTheOutputsOfAnUninterruptedRun(_ crash: Case) async throws {
    let world = try await JobWorld()
    let ticker = Ticker()
    let model = FakeModel(freezing: crash.heartbeat ? [1] : [])
    let handle = try await world.start(world.runner(.once(at: crash.point), ticker: ticker), model)
    if crash.heartbeat {
      try await model.waitFrozen()
      world.clock.advance(120)
      ticker.tick()
    }
    #expect(await handle.result == .interrupted)
    let crashed = try await JobFixture.attempt(handle.attempt, in: world.store)
    if crash.point == .renewed { #expect(crashed.lease?.renewed == LeaseInstant(date: world.clock.now, source: .device).millis) }
    if crash.point == .renewing { #expect(crashed.lease?.renewed == JobFixture.epoch) }

    world.clock.advance(5)
    let resumed = try await world.runner().resumeInterrupted { _ in world.pipeline(FakeModel()) }
    let finished = [AttemptRunner.Faults.Point.afterCommit(step: 2), .committed(write: Self.writes - 1)].contains(crash.point)
    #expect(resumed.map(\.attempt) == (finished ? [] : [handle.attempt]))
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }

    try await world.expectOutputsWrittenOnce()
    let attempt = try await JobFixture.attempt(handle.attempt, in: world.store)
    #expect(attempt.outcome == .succeeded)
    #expect(attempt.calls.count == crash.calls && Set(attempt.calls).count == crash.calls)
    #expect(Array(attempt.calls.prefix(crashed.calls.count)) == crashed.calls)
    #expect(try await world.status() == .succeeded(handle.attempt))
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldSettleAnAttemptStoppedBeforeTheCrashWithItsMarkInsteadOfResumingIt() async throws {
    let world = try await JobWorld()
    let model = FakeModel(freezing: [1])
    let runner = world.runner(.once(at: .settling))
    let handle = try await world.start(runner, model)
    try await model.waitFrozen()
    _ = try await runner.cancel(job: world.key.ref)
    #expect(await handle.result == .interrupted)
    #expect(try await JobFixture.localRuns(in: world.store).map(\.stop) == [.cancelled])
    #expect(try await world.runner().resumeInterrupted { _ in world.pipeline(FakeModel()) }.isEmpty)
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).outcome == .cancelled)
    try await world.expectOutputsWrittenOnce(["draft"])
    #expect(try await JobFixture.localRuns(in: world.store).isEmpty)
  }

  @Test func shouldStopAResumedAttemptWhoseJobWasCancelledWhileTheDeviceWasDown() async throws {
    let world = try await JobWorld()
    let handle = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await handle.result == .interrupted)
    _ = try await world.store.write { transaction in try JobRecords.cancel(try JobFixture.key().ref, in: &transaction) }
    let resumed = try await world.runner().resumeInterrupted { _ in world.pipeline(FakeModel()) }
    #expect(resumed.count == 1)
    for run in resumed { #expect(await run.result == .settled(.cancelled)) }
    try await world.expectOutputsWrittenOnce(["draft"])
  }

  @Test func shouldResumeAnAttemptOnceWithALeaseFromTheResumeEvenWhenTwoResumesRace() async throws {
    let world = try await JobWorld()
    let handle = try await world.start(world.runner(.once(at: .afterCommit(step: 0))), FakeModel())
    #expect(await handle.result == .interrupted)
    let model = FakeModel(freezing: [0])
    let runner = world.runner()
    world.clock.advance(400)
    async let first = runner.resumeInterrupted { _ in world.pipeline(model) }
    async let second = runner.resumeInterrupted { _ in world.pipeline(model) }
    let resumed = try await first + second
    #expect(resumed.map(\.attempt) == [handle.attempt])
    try await model.waitFrozen()
    #expect(try await JobFixture.attempt(handle.attempt, in: world.store).lease?.renewed == LeaseInstant(date: world.clock.now, source: .device).millis)
    #expect(try await world.status() == .running(handle.attempt))
    #expect(try await runner.resumeInterrupted { _ in world.pipeline(model) }.isEmpty)
    _ = try await runner.cancel(job: world.key.ref)
    for run in resumed { #expect(await run.result == .settled(.cancelled)) }
  }
}
