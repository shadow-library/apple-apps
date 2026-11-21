import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// The phone runs the generate itself with Run here and is interrupted mid-call with its lease released, as when its background time ends; the Mac worker
/// may take the lapsed job over, and what happens next depends on who resumes and how each attempt was started.
@Suite("Hand-off: the phone interrupts and the Mac takes over", TestTimeLimit.standard)
struct HandOffTakeoverTests {
  private struct Interrupted {
    let world: HandOffWorld
    let job: EntityRef
    let attempt: AttemptID
    let released: LeaseInstant
  }

  /// The Mac named the worker and the plan applied on both; the phone asked for the generate, ran it here and was interrupted in its first call, unsynced.
  private static func interrupted(seed: UInt64, ahead: [Int]? = nil, delivering: Bool = false) async throws -> Interrupted {
    let world = try await HandOffWorld.make([.phone, .mac()], seed: seed, ahead: ahead)
    let (phone, mac) = (world[0], world[1])
    try await mac.engine.designateWorker(.thisReplica)
    try await world.sync()
    try await world.handOff(.plan, worker: 1)
    let job = try await ChapterStage.generate.request(on: phone)
    let cut = phone.model.holdNextCall()
    let first = try await phone.engine.runHere(job: job)
    try await phone.waitUntilReached(cut)
    if delivering { try await world.deliver(from: 0, to: 1) }
    let released = phone.clock.instant
    #expect(try await phone.engine.interrupt(job: job, releasingLease: true) == .interrupted(first.attempt))
    #expect(await first.result == .interrupted)
    guard case .interrupted(let here)? = try await phone.placement(of: job) else { throw EngineFixtureError(description: "the phone's run is not interrupted") }
    #expect(here.attempt == first.attempt && here.renewal == released.date && here.queued.waitingFor == .worker(.named(world.device(1, seenFrom: 0))))
    return Interrupted(world: world, job: job, attempt: first.attempt, released: released)
  }

  private static func expectRunningElsewhere(_ device: ChapterDevice, job: EntityRef, leader: AttemptID, on replica: ReplicaID, byHand: Bool = false) async {
    do {
      _ = try await (byHand ? device.engine.runHere(job: job) : device.engine.run(job: job))
      Issue.record("replica \(device.index) started beside a live attempt")
    } catch JobEngineError.runningElsewhere(let attempt, let elsewhere) {
      #expect(attempt == leader && elsewhere == replica)
    } catch {
      Issue.record("replica \(device.index) refused with \(error)")
    }
  }

  /// The job succeeded elsewhere: the run the phone still holds stands down as soon as it resumes and writes nothing.
  private static func expectLateResumeStandsDown(_ phone: ChapterDevice, job: EntityRef, winner: AttemptID) async throws {
    #expect(try await phone.placement(of: job) == .succeeded(winner))
    let late = try await phone.engine.resumeHere(job: job)
    #expect(await late.result == .settled(.stoodDown))
    #expect(try await phone.engine.interruptedRuns().isEmpty)
  }

  @Test func shouldStandTheMacsTakeoverDownWhenThePhoneResumesItsEarlierRunByHand() async throws {
    let run = try await Self.interrupted(seed: 0x4861)
    let (world, job) = (run.world, run.job)
    let (phone, mac) = (world[0], world[1])
    try await world.deliver(from: 0, to: 1)
    let lapsed = try #require(try await mac.backlog().jobs.value?.first)
    #expect(lapsed.job == job && lapsed.latest?.attempt == run.attempt && lapsed.latest?.replica == phone.replica)

    let taking = mac.model.holdNextCall()
    let takeover = try #require(try await mac.drain().first)
    try await mac.waitUntilReached(taking)
    try await world.deliver(from: 1, to: 0)
    guard case .running(let running)? = try await phone.placement(of: job) else { throw EngineFixtureError(description: "the Mac's takeover is not seen") }
    #expect(running.attempt == takeover.attempt && running.device == world.device(1, seenFrom: 0))
    #expect(try await phone.engine.interruptedRuns().map(\.attempt) == [run.attempt])

    phone.model.queue(ChapterStage.generate.calls())
    let resuming = phone.model.holdNextCall()
    let resumed = try await phone.engine.resumeHere(job: job)
    #expect(resumed.attempt == run.attempt)
    try await phone.waitUntilReached(resuming)
    try await world.deliver(from: 0, to: 1)
    #expect(await takeover.result == .settled(.stoodDown))
    resuming.release()
    #expect(await resumed.result == .settled(.succeeded))
    try await world.sync()

    let attempts = try await mac.attempts(job)
    let kept = try #require(attempts.first { $0.id == run.attempt })
    let stood = try #require(attempts.first { $0.id == takeover.attempt })
    #expect(attempts.count == 2 && kept.outcome == .succeeded && kept.start.byHand && kept.start.started.millis < stood.start.started.millis)
    #expect(stood.outcome == .stoodDown && !stood.start.byHand && stood.calls.count == 1 && mac.model.requests == 0)
    for stage in [ChapterStage.review, .finalizeReview, .canonRefresh] { try await world.handOff(stage, worker: 1) }
    try await world.expectSameWorkAsOneDevice(through: .canonRefresh, cutCalls: 1)
  }

  @Test func shouldRefuseThePhonesResumeBesideTheMacsRunByHand() async throws {
    let run = try await Self.interrupted(seed: 0x4863)
    let (world, job) = (run.world, run.job)
    let (phone, mac) = (world[0], world[1])
    try await world.deliver(from: 0, to: 1)
    let sent = phone.model.requests
    mac.model.queue(ChapterStage.generate.calls())
    let taking = mac.model.holdNextCall()
    let takeover = try await mac.engine.runHere(job: job)
    try await mac.waitUntilReached(taking)
    try await world.deliver(from: 1, to: 0)

    let engine = try phone.engine
    do throws(JobEngineError) {
      _ = try await engine.resumeHere(job: job)
      Issue.record("the phone resumed beside the Mac's run by hand")
    } catch .runningElsewhere(let attempt, let replica) {
      #expect(attempt == takeover.attempt && replica == mac.replica)
    } catch {
      Issue.record("the phone's resume refused with \(error)")
    }
    #expect(try await phone.engine.interruptedRuns().map(\.attempt) == [run.attempt], "a refused resume keeps the checkpoint")
    #expect(phone.model.requests == sent)
    taking.release()
    #expect(await takeover.result == .settled(.succeeded))
    try await world.sync()
    try await Self.expectLateResumeStandsDown(phone, job: job, winner: takeover.attempt)
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }

  /// The release reaches the Mac only with the phone's next sync: until then the Mac reads the phone's run live, lists nothing and cannot start the job.
  @Test func shouldKeepAReleasedLeaseLiveOnTheMacUntilThePhoneSyncs() async throws {
    let run = try await Self.interrupted(seed: 0x4865, delivering: true)
    let (world, job) = (run.world, run.job)
    let (phone, mac) = (world[0], world[1])
    guard case .running(let running)? = try await mac.placement(of: job) else { throw EngineFixtureError(description: "the Mac does not see the phone's run") }
    #expect(running.attempt == run.attempt && running.device == world.device(0, seenFrom: 1))
    #expect(try await mac.backlog().jobs.value == [])
    #expect(try await mac.drain().isEmpty)
    await Self.expectRunningElsewhere(mac, job: job, leader: run.attempt, on: phone.replica)
    await Self.expectRunningElsewhere(mac, job: job, leader: run.attempt, on: phone.replica, byHand: true)

    try await world.deliver(from: 0, to: 1)
    #expect(try await mac.placement(of: job).map { if case .queued = $0 { true } else { false } } == true)
    mac.model.queue(ChapterStage.generate.calls())
    let takeover = try await mac.drainToEnd(job)
    try await world.sync()
    try await Self.expectLateResumeStandsDown(phone, job: job, winner: takeover.attempt)
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }

  /// The phone's clock runs 200 s ahead of the Mac's, inside the 300 s skew limit: the Mac reads the released lease live until its own clock reaches the
  /// release, says when that is, and takes the job over then.
  @Test func shouldTakeTheJobOverOnceAClockBehindThePhoneReachesTheRelease() async throws {
    let run = try await Self.interrupted(seed: 0x4867, ahead: [200, 0])
    let (world, job) = (run.world, run.job)
    let (phone, mac) = (world[0], world[1])
    #expect(mac.clock.now.addingTimeInterval(200) == phone.clock.now)
    try await world.deliver(from: 0, to: 1)
    let waiting = try await mac.backlog()
    #expect(waiting.jobs.value == [] && waiting.changesAt == run.released.date)
    guard case .running(let running)? = try await mac.placement(of: job) else { throw EngineFixtureError(description: "the Mac reads the lease lapsed") }
    #expect(running.attempt == run.attempt && running.expiry == run.released.date)
    await Self.expectRunningElsewhere(mac, job: job, leader: run.attempt, on: phone.replica)

    await world.advance(1, by: 199)
    #expect(try await mac.backlog().jobs.value == [])
    await world.advance(1, by: 1)
    mac.model.queue(ChapterStage.generate.calls())
    let takeover = try await mac.drainToEnd(job)
    try await world.sync()
    try await Self.expectLateResumeStandsDown(phone, job: job, winner: takeover.attempt)
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }

  /// The Mac's clock runs 200 s behind the phone's, inside the skew limit, so an attempt it starts now is stamped before the phone's live run by hand: an
  /// automatic start would outrank that run, neither would stand down and both would write. The Mac reads the run live and refuses, as its backlog does.
  @Test func shouldRefuseAnAutomaticStartBesideALiveRunByHandStampedLaterByAClockAhead() async throws {
    let world = try await HandOffWorld.make([.phone, .mac()], seed: 0x4869, ahead: [200, 0])
    let (phone, mac) = (world[0], world[1])
    try await mac.engine.designateWorker(.thisReplica)
    try await world.sync()
    try await world.handOff(.plan, worker: 1)
    let job = try await ChapterStage.generate.request(on: phone)
    phone.model.queue(ChapterStage.generate.calls())
    let hold = phone.model.holdNextCall()
    let running = try await phone.engine.runHere(job: job)
    try await phone.waitUntilReached(hold)
    try await world.deliver(from: 0, to: 1)
    #expect(try await mac.backlog().jobs.value == [])
    await Self.expectRunningElsewhere(mac, job: job, leader: running.attempt, on: phone.replica)
    hold.release()
    #expect(await running.result == .settled(.succeeded))
    try await world.sync()
    #expect(try await mac.attempts(job).map(\.id) == [running.attempt])
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }

  /// The worker Mac sleeps mid-call, so its lease lapses, and the phone runs the job here by hand: once the phone's run reaches it the Mac's automatic
  /// attempt stands down at once, though it started first, having spent only the call it had in flight, and that call is charged to the run.
  @Test func shouldStandTheSleptWorkersRunDownWhenThePhoneRunsTheJobByHand() async throws {
    let world = try await HandOffWorld.make([.phone, .mac()], seed: 0x486B)
    let (phone, mac) = (world[0], world[1])
    try await mac.engine.designateWorker(.thisReplica)
    try await world.sync()
    try await world.handOff(.plan, worker: 1)
    let job = try await ChapterStage.generate.request(on: phone)
    try await world.sync()
    let asleep = mac.model.holdNextCall()
    let slept = try #require(try await mac.drain().first)
    try await mac.waitUntilReached(asleep)
    try await world.deliver(from: 1, to: 0)
    #expect(try await phone.placement(of: job).map { if case .running = $0 { true } else { false } } == true)

    for device in [0, 1] { await world.advance(device, by: 420) }
    guard case .queued(let lapsed)? = try await phone.placement(of: job) else { throw EngineFixtureError(description: "the slept lease reads live") }
    #expect(lapsed.latest?.attempt == slept.attempt && lapsed.latest?.replica == mac.replica)
    phone.model.queue(ChapterStage.generate.calls())
    let held = phone.model.holdNextCall()
    let here = try await phone.engine.runHere(job: job)
    try await phone.waitUntilReached(held)
    try await world.deliver(from: 0, to: 1)
    #expect(await slept.result == .settled(.stoodDown), "the Mac yields while the phone's run is still in its call")
    held.release()
    #expect(await here.result == .settled(.succeeded))
    try await world.sync()

    let attempts = try await phone.attempts(job)
    let stood = try #require(attempts.first { $0.id == slept.attempt })
    let won = try #require(attempts.first { $0.id == here.attempt })
    #expect(attempts.count == 2 && stood.start.started.millis < won.start.started.millis && !stood.start.byHand && won.start.byHand)
    #expect(stood.outcome == .stoodDown && stood.calls.count == 1 && mac.model.requests == 0, "the Mac spent only its call in flight")
    let charges = try await phone.store.load(ChapterRunCharges.self, ChapterRunChargesQuery(novel: ChapterReplicas.novel, chapter: ChapterStage.chapter))
    let charge = try #require(charges.runs.value?.first { $0.job == job })
    #expect(charge.cost.calls == won.calls.count + stood.calls.count && charge.cost.pendingCalls == 1)
    try await world.expectSameWorkAsOneDevice(through: .generate)
  }
}
