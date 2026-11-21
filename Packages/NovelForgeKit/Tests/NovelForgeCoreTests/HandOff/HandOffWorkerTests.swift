import Foundation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// The phone asks, the Mac named the vault's worker writes: the chapter's whole chain handed across devices leaves what one device doing it all leaves.
@Suite("Hand-off: the Mac worker runs what the phone asks", TestTimeLimit.standard)
struct HandOffWorkerTests {
  @Test func shouldRunEveryJobThePhoneAsksForOnTheMacWorkerWhileThePhoneShowsWhereAndFinalizes() async throws {
    let world = try await HandOffWorld.make([.phone, .mac()], seed: 0x4851)
    let (phone, mac) = (world[0], world[1])
    #expect(try await mac.engine.designateWorker(.thisReplica) == .named(world.device(1, seenFrom: 1)))
    try await world.sync()
    #expect(try await phone.engine.worker() == .named(world.device(1, seenFrom: 0)))

    var jobs: [ChapterStage: EntityRef] = [:]
    for stage in ChapterStage.allCases {
      guard stage == .generate else {
        jobs[stage] = try await world.handOff(stage, worker: 1)
        continue
      }
      let job = try await stage.request(on: phone)
      jobs[stage] = job
      let backlog = try await phone.backlog()
      #expect(backlog.jobs.value?.map(\.job) == [job] && !backlog.isWorkerHere)
      #expect(try await phone.drain().isEmpty)
      try await world.sync()
      let hold = mac.model.holdNextCall()
      mac.model.queue(stage.calls())
      let handle = try #require(try await mac.drain().first)
      try await mac.waitUntilReached(hold)
      try await world.deliver(from: 1, to: 0)
      guard case .running(let running)? = try await phone.placement(of: job) else {
        Issue.record("the phone does not see the generate running on the Mac")
        return
      }
      #expect(running.attempt == handle.attempt && running.device == world.device(1, seenFrom: 0))
      #expect(running.step == AttemptStep(name: "draft", index: 1))
      hold.release()
      #expect(await handle.result == .settled(.succeeded))
      try await world.sync()
      #expect(try await phone.placement(of: job) == .succeeded(handle.attempt))
    }

    let baseline = try await HandOffBaseline.recording.value
    #expect(phone.model.scripted.requests.map(ChainScript.name) == baseline.calls[.plan])
    #expect(mac.model.scripted.requests.map(ChainScript.name) == ChapterStage.allCases.dropFirst().flatMap { baseline.calls[$0] ?? [] })
    for (stage, job) in jobs {
      let attempts = try await phone.attempts(job)
      #expect(attempts.count == 1 && attempts.allSatisfy { $0.outcome == .succeeded && !$0.start.byHand }, "\(stage)")
      #expect(attempts.first?.start.replica == (stage == .plan ? phone.replica : mac.replica), "\(stage) ran on its device")
    }
    #expect(try await phone.isFinal())
    try await world.expectSameWorkAsOneDevice(through: .canonRefresh)
  }

  /// Both Macs were named the worker on their own before either heard of the other: both drain the phone's generate, the later start stands down when they
  /// hear of each other, and its one call in flight is the only spend twice over, charged to the run. Once the designations converge only the later one
  /// drains.
  @Test func shouldLetOneOfTwoSelfNamedWorkersWinAJobAndOnlyTheLaterDesignationDrainOnceConverged() async throws {
    let world = try await HandOffWorld.make([.phone, .mac(), .mac("Desk Mac")], seed: 0x4853)
    let (phone, first, second) = (world[0], world[1], world[2])
    try await first.engine.designateWorker(.thisReplica)
    try await second.engine.designateWorker(.thisReplica)
    let plan = try await ChapterStage.plan.request(on: phone)
    phone.model.queue(ChapterStage.plan.calls())
    #expect(await (try await phone.engine.run(job: plan)).result == .settled(.succeeded))
    try await ChapterStage.plan.complete(on: phone, job: plan)
    let job = try await ChapterStage.generate.request(on: phone)
    for mac in [1, 2] { try await world.deliver(from: 0, to: mac) }
    for mac in [first, second] {
      let backlog = try await mac.backlog()
      #expect(backlog.isWorkerHere && backlog.jobs.value?.map(\.job) == [job], "replica \(mac.index) reads itself the worker")
    }

    let holds = [first.model.holdNextCall(), second.model.holdNextCall()]
    first.model.queue(ChapterStage.generate.calls())
    let winner = try #require(try await first.drain().first)
    let loser = try #require(try await second.drain().first)
    for (mac, hold) in zip([first, second], holds) { try await mac.waitUntilReached(hold) }
    try await world.deliver(from: 1, to: 2)
    try await world.deliver(from: 2, to: 1)
    #expect(await loser.result == .settled(.stoodDown))
    holds[0].release()
    #expect(await winner.result == .settled(.succeeded))
    try await world.sync()

    let attempts = try await phone.attempts(job)
    #expect(Set(attempts.map(\.id)) == [winner.attempt, loser.attempt] && attempts.count == 2)
    let lost = try #require(attempts.first { $0.id == loser.attempt })
    let won = try #require(attempts.first { $0.id == winner.attempt })
    #expect(lost.outcome == .stoodDown && lost.calls.count == 1 && second.model.requests == 0, "the loser spent only the call it had in flight")
    #expect(won.outcome == .succeeded && won.calls.count == first.model.requests)
    let charges = try await phone.store.load(ChapterRunCharges.self, ChapterRunChargesQuery(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter))
    let charge = try #require(charges.runs.value?.first { $0.job == job })
    #expect(charge.cost.calls == won.calls.count + lost.calls.count && charge.cost.pendingCalls == 1 && charge.cost.isPending)

    let later = VaultWorker.named(world.device(2, seenFrom: 0))
    #expect(try await phone.engine.worker() == later)
    #expect(try await first.engine.worker() == .named(world.device(2, seenFrom: 1)))
    #expect(!(try await first.backlog().isWorkerHere))
    #expect(try await second.backlog().isWorkerHere)
    for stage in [ChapterStage.review, .finalizeReview, .canonRefresh] { try await world.handOff(stage, worker: 2, bystanders: [1]) }
    #expect(first.model.requests == ChapterStage.generate.calls().count, "the earlier designation ran nothing once it heard of the later")
    try await world.expectSameWorkAsOneDevice(through: .canonRefresh)
  }

  /// The worker Mac was set up again as a new replica that succeeds the old one: every device follows the designation to the successor, which drains.
  @Test func shouldFollowARetiredWorkerToItsSuccessorWhichDrainsThePhonesJobs() async throws {
    let world = try await HandOffWorld.make([.phone, .mac(), .mac()], seed: 0x4855)
    let (phone, retired, successor) = (world[0], world[1], world[2])
    try await retired.engine.designateWorker(.thisReplica)
    try await world.sync()
    let (old, new) = (retired.replica, successor.replica)
    _ = try await world.replicas.write(2) { transaction in try ReplicaDirectory.retire(old, successor: new, in: &transaction) }
    try await world.sync()
    #expect(try await phone.engine.worker() == .named(world.device(2, seenFrom: 0)))
    #expect(!(try await retired.backlog().isWorkerHere))
    #expect(try await successor.backlog().isWorkerHere)

    try await world.handOff(.plan, worker: 2)
    try await world.handOff(.generate, worker: 2, bystanders: [1])
    #expect(retired.model.requests == 0)
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }
}
