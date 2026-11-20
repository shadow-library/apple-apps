import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// A plan job killed at every runner write, inside its call and around each commit, then resumed by a new engine as a relaunch does, stages exactly one card.
@Suite("Plan pipeline crashes", TestTimeLimit.standard)
struct PlanPipelineCrashTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let point: AttemptRunner.Faults.Point
    /// Model calls over both runs: two when the crash lost the plan call or its output.
    let calls: Int
    let finished: Bool

    var testDescription: String { "\(point)" }
  }

  static let cases: [Case] = [
    Case(point: .committed(write: 0), calls: 1, finished: false), Case(point: .call(step: 0), calls: 2, finished: false),
    Case(point: .beforeCommit(step: 0), calls: 2, finished: false), Case(point: .afterCommit(step: 0), calls: 1, finished: false),
    Case(point: .committed(write: 1), calls: 1, finished: false), Case(point: .beforeCommit(step: 1), calls: 1, finished: false),
    Case(point: .afterCommit(step: 1), calls: 1, finished: true), Case(point: .committed(write: 2), calls: 1, finished: true),
  ]

  @Test(arguments: cases)
  func shouldStageExactlyOneCardWhenKilledAndResumed(_ crash: Case) async throws {
    let world = try await PlanJobWorld(calls: 2)
    let engine = try world.engine(.once(at: crash.point))
    let receipt = try await world.request(engine)
    let handle = try await engine.run(job: receipt.job.ref)
    #expect(await handle.result == .interrupted)
    engine.relinquish()

    world.engineWorld.clock.advance(5)
    let relaunched = try world.engine()
    let resumed = try await relaunched.resumeInterruptedAttempts()
    #expect(resumed.map(\.attempt) == (crash.finished ? [] : [handle.attempt]))
    for run in resumed { #expect(await run.result == .settled(.succeeded)) }

    #expect(world.provider.requests.count == crash.calls)
    #expect(try await world.card(of: receipt.job) != nil)
    #expect(try await world.cardWrites(of: receipt.job) == 1)
    #expect(try await world.proposals().count == 1)
    #expect(try await world.engineWorld.status(receipt.job.ref) == .succeeded(handle.attempt))
  }

  // plan-job.service.ts:146-151: a later attempt of a job whose card is already staged settles with no call
  @Test func shouldSettleALaterAttemptOfAStagedJobWithNoCall() async throws {
    let world = try await PlanJobWorld(calls: 1)
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    try await Self.preStage(receipt.job, in: world)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    #expect(world.provider.requests.isEmpty)
    #expect(try await world.cardWrites(of: receipt.job) == 1)
  }

  // action-jobs.ts:61-72: the card is found already there when the stage step runs, so the stage writes nothing
  @Test func shouldStageNothingWhenTheCardArrivedBeforeTheStageStep() async throws {
    let world = try await PlanJobWorld(calls: 1)
    let engine = try world.engine(.once(at: .afterCommit(step: 0)))
    let receipt = try await world.request(engine)
    #expect(try await engine.run(job: receipt.job.ref).result == .interrupted)
    engine.relinquish()
    try await Self.preStage(receipt.job, in: world)
    let resumed = try #require(try await world.engine().resumeInterruptedAttempts().first)
    #expect(await resumed.result == .settled(.succeeded))
    #expect(world.provider.requests.count == 1)
    #expect(try await world.cardWrites(of: receipt.job) == 1)
    #expect(try await world.card(of: receipt.job)?.card.changeSet.first?.stored["body"] == .string("Mara waits."))
  }

  private static func preStage(_ job: JobKey, in world: PlanJobWorld) async throws {
    let card = PlanCards.id(of: job.ref)
    let novel = world.novel
    try await world.store.write { transaction in
      let changeSet = try ValidatedChangeSet(.array([jsonObject([("op", .string("brief.update")), ("chapter", .int(1)), ("body", .string("Mara waits."))])]))
      _ = try ProposalStager.stage(ProposalStagingInput(novel: novel, kind: .chapterPlan, changeSet: changeSet), id: card, in: &transaction)
    }
  }
}
