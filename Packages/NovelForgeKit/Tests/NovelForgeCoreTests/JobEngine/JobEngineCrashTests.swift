import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A two-step pipeline of real chapter calls is killed at every runner write, inside each call's opening transaction, around each commit and around a
/// heartbeat during a call; a new engine on the same vault resumes it as a relaunch does. The attempt ends with the outputs of an uninterrupted run, each
/// written once, its pack built once, and every ledger call, the killed one included, on the attempt.
@Suite("Job engine crashes", TestTimeLimit.standard)
struct JobEngineCrashTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let point: AttemptRunner.Faults.Point
    /// Calls the attempt records over both runs: one more than the two steps when the crash cut a call off or lost a step's output.
    let calls: Int
    var heartbeat = false

    var testDescription: String { "\(point)" }
  }

  /// The start and one commit per step.
  static let writes = 3

  static let cases: [Case] =
    (0..<writes).map { Case(point: .committed(write: $0), calls: 2) }
    + (0..<2).flatMap { step in
      [Case(point: .call(step: step), calls: 3), Case(point: .beforeCommit(step: step), calls: 3), Case(point: .afterCommit(step: step), calls: 2)]
    }
    + [Case(point: .renewing, calls: 3, heartbeat: true), Case(point: .renewed, calls: 3, heartbeat: true)]

  @Test(arguments: cases)
  func shouldResumeAKilledAttemptToTheOutputsOfAnUninterruptedRun(_ crash: Case) async throws {
    let scripts = crash.heartbeat ? [JobEngineWorld.reply(), JobEngineWorld.frozen, JobEngineWorld.reply()] : Array(repeating: JobEngineWorld.reply(), count: 3)
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: scripts))
    let engine = try world.engine(.once(at: crash.point))
    let job = try await world.request(engine).ref
    let handle = try await engine.run(job: job)
    if crash.heartbeat {
      try await world.waitForRequests(2)
      world.clock.advance(120)
      world.heartbeat.open()
    }
    #expect(await handle.result == .interrupted)
    let killed = try await world.attempt(handle.attempt)
    engine.relinquish()

    world.clock.advance(5)
    let relaunched = try world.engine()
    let resumed = try await relaunched.resumeInterruptedAttempts()
    let finished = [AttemptRunner.Faults.Point.afterCommit(step: 1), .committed(write: Self.writes - 1)].contains(crash.point)
    #expect(resumed.map(\.attempt) == (finished ? [] : [handle.attempt]))
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }

    try await world.expectOutputsWrittenOnce(job)
    let attempt = try await world.attempt(handle.attempt)
    #expect(attempt.outcome == .succeeded)
    #expect(attempt.calls.count == crash.calls && Set(attempt.calls).count == crash.calls)
    #expect(Array(attempt.calls.prefix(killed.calls.count)) == killed.calls)
    let ledger = try await world.ledgerIDs()
    #expect(Set(attempt.calls) == Set(ledger))
    #expect(world.packs.builds == 1)
    let built = try #require(world.packs.built.first)
    #expect(built.contains("heir"))
    #expect(Set(try await world.outputs(of: job).withholdings.values) == [built])
    #expect(try await world.status(job) == .succeeded(handle.attempt))
    #expect(try await world.localRuns().isEmpty)
    #expect(try await world.pinnedPacks() == 0)
  }

  @Test func shouldStartAgainWithNothingWrittenWhenKilledAfterPinning() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider(calls: [JobEngineWorld.reply(), JobEngineWorld.reply()]))
    let killed = try world.engine(engineFaults: JobEngine.Faults { $0 == .pinned })
    let job = try await world.request(killed).ref
    await #expect(throws: JobEngineError.self) { _ = try await killed.run(job: job) }
    #expect(try await world.store.read { transaction in try JobSnapshot.load(job, in: transaction) }?.attempts.isEmpty == true)
    killed.relinquish()
    let engine = try world.engine()
    #expect(try await engine.resumeInterruptedAttempts().isEmpty)
    let handle = try await engine.run(job: job)
    #expect(await handle.result == .settled(.succeeded))
    try await world.expectOutputsWrittenOnce(job)
  }
}
