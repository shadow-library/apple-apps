import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = JobWorld

private func date(_ seconds: Int64) -> Date { World.instant(seconds).date }

private let phone = World.replicas[0]
private let mac = World.replicas[1]
private let tablet = World.replicas[2]

private func replica(_ number: Int) -> ReplicaID {
  ReplicaID(UUID(uuidString: String(format: "00000000-0000-7000-8000-1000000000%02d", number)) ?? UUID())
}

private func declare(_ replica: ReplicaID, name: String, platform: String = "macOS", in store: VaultStore) async throws {
  _ = try await Projection.write(store) { transaction in
    try ReplicaDirectory.declareActive(replica, name: name, platform: platform, createdMillis: World.epoch, in: &transaction)
  }
}

private func retire(_ replica: ReplicaID, successor: ReplicaID?, in store: VaultStore) async throws {
  _ = try await Projection.write(store) { transaction in try ReplicaDirectory.retire(replica, successor: successor, in: &transaction) }
}

private func designate(_ replica: ReplicaID?, at seconds: Int64 = 0, in store: VaultStore) async throws {
  _ = try await Projection.write(store) { transaction in try WorkerRecords.designate(replica, at: World.instant(seconds), in: &transaction) }
}

private func backlog(here: ReplicaID = phone, at seconds: Int64, in store: VaultStore) async throws -> WorkerBacklog {
  try await store.load(WorkerBacklog.self, WorkerBacklogQuery(replica: here, now: World.instant(seconds)))
}

private func placements(_ jobs: [EntityRef], here: ReplicaID = phone, at seconds: Int64, in store: VaultStore) async throws -> JobPlacements {
  try await store.load(JobPlacements.self, JobPlacementQuery(jobs: jobs, replica: here, now: World.instant(seconds)))
}

private func settle(_ attempt: AttemptID, _ settlement: AttemptSettlement, by replica: ReplicaID = phone, in store: VaultStore) async throws {
  try await World.update(attempt, AttemptUpdate(settlement: settlement), replica: replica, in: store)
}

private let failure = AttemptFailure(code: "ai.timeout", message: "The call timed out.")

@Suite("Worker backlog and job placement", TestTimeLimit.standard)
struct WorkerPlacementTests {
  @Test func shouldListQueuedJobsOfWorkerKindsVaultWideAndAddALapsedLeaseWithNoWrite() async throws {
    let (reconciler, store) = try World.store()
    let fresh = try await World.request(try World.key(chapter: 1), replica: phone, in: store)
    let lapsing = try await World.request(try World.key(chapter: 2), replica: tablet, in: store)
    let running = try await World.start(lapsing, at: 0, replica: mac, seed: 1, in: store)
    let failed = try await World.request(try World.key(chapter: 3, kind: .review), in: store)
    try await settle(try await World.start(failed, at: 0, seed: 2, in: store), .failed(failure), in: store)
    let cancelled = try await World.request(try World.key(chapter: 4, kind: .canonRefresh), in: store)
    _ = try await World.start(cancelled, at: 0, seed: 3, in: store)
    _ = try await Projection.write(store) { transaction in try JobRecords.cancel(cancelled, in: &transaction) }
    let succeeded = try await World.request(try World.key(chapter: 5, kind: .finalizeReview), in: store)
    try await settle(try await World.start(succeeded, at: 0, seed: 4, in: store), .succeeded, in: store)
    try await World.request(try World.key(chapter: 6, kind: .plan), in: store)
    try await World.request(try JobKey(scope: "vault", kind: NovelJobKind.generate.rawValue, target: "all", fingerprint: "f", run: 1), in: store)
    let writes = try await store.pendingChanges(limit: Int.max).count

    let early = try await backlog(at: 10, in: store)
    #expect(early.jobs.value?.map(\.job) == [fresh] && early.changesAt == date(360))
    #expect(early.jobs.value?.first?.latest == nil && early.jobs.value?.first?.requester == phone && early.jobs.value?.first?.kind == .generate)

    let late = try await backlog(at: 360, in: store)
    #expect(late.jobs.value?.map(\.job) == [fresh, lapsing] && late.changesAt == nil)
    let lapsed = try #require(late.jobs.value?.last?.latest)
    #expect(lapsed.attempt == running && lapsed.replica == mac && lapsed.step == AttemptStep(name: "draft", index: 0) && lapsed.renewal == date(0))
    #expect(late.jobs.value?.last?.chapter == 2 && late.jobs.value?.last?.novel == World.novel)
    #expect(try await store.pendingChanges(limit: Int.max).count == writes)

    try await World.update(running, AttemptUpdate(lease: .granted(at: World.instant(400))), replica: mac, in: store)
    let renewed = try await backlog(at: 401, in: store)
    #expect(renewed.jobs.value?.map(\.job) == [fresh] && renewed.changesAt == date(760))
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldLeaveAJobOutUntilALeaseStampedTooFarAheadOpensAndSayWhen() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let attempt = try await World.start(job, at: 0, replica: mac, in: store)
    try await World.update(attempt, AttemptUpdate(lease: .granted(at: World.instant(1_000))), replica: mac, in: store)
    let skewed = try await backlog(at: 300, in: store)
    #expect(skewed.jobs.value?.map(\.job) == [job] && skewed.changesAt == date(700))
    let opened = try await backlog(at: 700, in: store)
    #expect(opened.jobs.value == [] && opened.changesAt == date(1_360))
    #expect(try await backlog(at: 1_360, in: store).jobs.value?.map(\.job) == [job])
  }

  @Test func shouldPlaceEveryKindOfJobForThisReplica() async throws {
    let (_, store) = try World.store()
    try await declare(phone, name: "Pocket iPhone", platform: "iOS", in: store)
    try await declare(mac, name: "Studio Mac", in: store)
    try await designate(mac, in: store)
    let queued = try await World.request(try World.key(chapter: 1), in: store)
    let plan = try await World.request(try World.key(chapter: 1, kind: .plan), in: store)
    let running = try await World.request(try World.key(chapter: 2), in: store)
    let runningAttempt = try await World.start(running, at: 0, replica: mac, seed: 1, in: store)
    try await World.update(runningAttempt, AttemptUpdate(lease: .granted(at: World.instant(100)), step: AttemptStep(name: "expand", index: 1)), replica: mac, in: store)
    let interrupted = try await World.request(try World.key(chapter: 3), in: store)
    let interruptedAttempt = try await World.start(interrupted, at: 0, byHand: true, seed: 2, in: store)
    try await World.update(interruptedAttempt, AttemptUpdate(lease: .released(at: World.instant(50))), in: store)
    let failed = try await World.request(try World.key(chapter: 4, kind: .review), in: store)
    let failedAttempt = try await World.start(failed, at: 0, seed: 3, in: store)
    try await settle(failedAttempt, .failed(failure), in: store)
    let cancelled = try await World.request(try World.key(chapter: 5), in: store)
    _ = try await Projection.write(store) { transaction in try JobRecords.cancel(cancelled, in: &transaction) }
    let succeeded = try await World.request(try World.key(chapter: 6, kind: .canonRefresh), in: store)
    let succeededAttempt = try await World.start(succeeded, at: 0, seed: 4, in: store)
    try await settle(succeededAttempt, .succeeded, in: store)
    let missing = try World.key(chapter: 7).ref

    let jobs = [queued, plan, running, interrupted, failed, cancelled, succeeded, missing]
    let read = try await placements(jobs, at: 150, in: store)
    let worker = VaultWorker.named(JobDevice(replica: mac, name: "Studio Mac", isHere: false))
    #expect(read.worker == worker && read.changesAt == date(460))
    #expect(read.placement(of: queued) == .queued(JobQueued(waitingFor: .worker(worker), requested: try #require(await requested(queued, in: store)), latest: nil)))
    let iPhone = JobDevice(replica: phone, name: "Pocket iPhone", isHere: true)
    #expect(read.placement(of: plan) == .queued(JobQueued(waitingFor: .requester(iPhone), requested: try #require(await requested(plan, in: store)), latest: nil)))
    let studio = JobDevice(replica: mac, name: "Studio Mac", isHere: false)
    #expect(
      read.placement(of: running)
        == .running(JobRunning(attempt: runningAttempt, device: studio, step: AttemptStep(name: "expand", index: 1), renewal: date(100), expiry: date(460))))
    guard case .interrupted(let stopped)? = read.placement(of: interrupted) else { throw PlacementFailure("the released run is not interrupted here") }
    #expect(stopped.attempt == interruptedAttempt && stopped.renewal == date(50) && stopped.step == AttemptStep(name: "draft", index: 0))
    #expect(stopped.queued.waitingFor == .worker(worker) && stopped.queued.latest?.attempt == interruptedAttempt)
    #expect(read.placement(of: failed) == .failed(failedAttempt, failure))
    #expect(read.placement(of: cancelled) == .cancelled)
    #expect(read.placement(of: succeeded) == .succeeded(succeededAttempt))
    #expect(read.placements.value?.keys.contains(missing) == false && read.placements.value?.count == 7)

    let onTheMac = try await placements([interrupted, running], here: mac, at: 150, in: store)
    guard case .queued(let waiting)? = onTheMac.placement(of: interrupted) else { throw PlacementFailure("another replica's released run is not queued") }
    #expect(waiting.waitingFor == .worker(.named(JobDevice(replica: mac, name: "Studio Mac", isHere: true))) && waiting.latest?.renewal == date(50))
    guard case .running(let here)? = onTheMac.placement(of: running) else { throw PlacementFailure("the Mac's run is not running") }
    #expect(here.device.isHere && onTheMac.worker.isHere)
    #expect(
      try await placements([running], at: 460, in: store).placement(of: running)
        == .queued(
          JobQueued(waitingFor: .worker(worker), requested: try #require(await requested(running, in: store)), latest: try #require(await latest(running, in: store)))))
  }

  @Test func shouldPlaceAJobWithAttemptsOnThreeReplicasAsJobStatusRanksThem() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let first = try await World.start(job, at: 0, replica: phone, byHand: true, seed: 1, in: store)
    try await World.update(first, AttemptUpdate(lease: .released(at: World.instant(30))), replica: phone, in: store)
    let second = try await World.start(job, at: 40, replica: tablet, seed: 2, in: store)
    try await settle(second, .stoodDown, by: tablet, in: store)
    let third = try await World.start(job, at: 50, replica: mac, seed: 3, in: store)

    guard case .running(let running)? = try await placements([job], at: 100, in: store).placement(of: job) else { throw PlacementFailure("not running") }
    #expect(running.attempt == third && running.device.replica == mac && running.device.name == nil)

    let lapsed = try await placements([job], at: 410, in: store)
    guard case .interrupted(let here)? = lapsed.placement(of: job) else { throw PlacementFailure("the phone's run is not interrupted here") }
    #expect(here.attempt == first && here.queued.latest?.attempt == third && here.queued.waitingFor == .worker(.none) && lapsed.changesAt == nil)
    guard case .queued(let elsewhere)? = try await placements([job], here: tablet, at: 410, in: store).placement(of: job) else {
      throw PlacementFailure("the tablet sees no queued job")
    }
    #expect(elsewhere.latest?.attempt == third && elsewhere.latest?.replica == mac)
    #expect(try await backlog(at: 410, in: store).jobs.value?.map(\.job) == [job])
  }

  @Test func shouldFollowARetiredWorkerToItsSuccessorAndNameIt() async throws {
    let (_, store) = try World.store()
    let (old, middle, current) = (replica(1), replica(2), replica(3))
    try await declare(current, name: "", platform: "macOS", in: store)
    try await retire(old, successor: middle, in: store)
    try await retire(middle, successor: current, in: store)
    try await designate(old, in: store)
    #expect(try await backlog(here: current, at: 0, in: store).worker == .named(JobDevice(replica: current, name: "macOS", isHere: true)))
    #expect(try await backlog(here: current, at: 0, in: store).isWorkerHere)
    #expect(try await backlog(here: old, at: 0, in: store).worker.isHere == false)

    let (gone, looped, loop) = (replica(4), replica(5), replica(6))
    try await retire(gone, successor: nil, in: store)
    try await designate(gone, in: store)
    #expect(try await backlog(at: 0, in: store).worker == .retired(gone))
    try await retire(looped, successor: loop, in: store)
    try await retire(loop, successor: looped, in: store)
    try await designate(looped, in: store)
    #expect(try await backlog(at: 0, in: store).worker == .retired(loop))
    let stranger = replica(7)
    try await designate(stranger, in: store)
    #expect(try await backlog(at: 0, in: store).worker == .named(JobDevice(replica: stranger, name: nil, isHere: false)))
  }

  @Test func shouldReadNoWorkerForAnAbsentANamedNoneOrAnUnreadableRecordAndStillListTheBacklog() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let absent = try await backlog(at: 0, in: store)
    #expect(absent.worker == .none && absent.jobs.value?.map(\.job) == [job])
    try await designate(mac, in: store)
    try await designate(nil, at: 5, in: store)
    #expect(try await backlog(at: 10, in: store).worker == .none)
    try await Projection.set(WorkerRecords.ref, [WorkerField.replica.rawValue: 5, WorkerField.since.rawValue: ["millis": 1, "clock": "trusted"]], in: store)
    let unreadable = try await backlog(here: mac, at: 10, in: store)
    guard case .unreadable = unreadable.worker else { throw PlacementFailure("an unreadable record reads \(unreadable.worker)") }
    #expect(!unreadable.isWorkerHere && unreadable.jobs.value?.map(\.job) == [job] && unreadable.faults.isEmpty)
    guard case .queued(let queued)? = try await placements([job], at: 10, in: store).placement(of: job), case .worker(.unreadable) = queued.waitingFor else {
      throw PlacementFailure("an unreadable worker is not read as none named")
    }
  }

  @Test func shouldLetTwoReplicasEachBelieveTheyAreTheWorkerUntilTheLaterDesignationReachesBoth() async throws {
    let reconciler = try Projection.reconciler()
    let clock = SchemaTestClock()
    let first = try Projection.store(reconciler, clock: clock)
    let second = try Projection.store(reconciler, clock: clock)
    let job = try await World.request(try World.key(), in: first)
    try await designate(first.replica, in: first)
    clock.advance()
    try await designate(second.replica, at: 1, in: second)
    #expect(try await backlog(here: first.replica, at: 10, in: first).isWorkerHere)
    #expect(try await backlog(here: second.replica, at: 10, in: second).isWorkerHere)

    let (fromFirst, fromSecond) = (try await Projection.lines(of: first), try await Projection.lines(of: second))
    try await Projection.apply(fromFirst, to: second)
    try await Projection.apply(fromSecond, to: first)
    let onFirst = try await backlog(here: first.replica, at: 10, in: first)
    let onSecond = try await backlog(here: second.replica, at: 10, in: second)
    #expect(onFirst.worker.device?.replica == second.replica && onSecond.worker.device?.replica == second.replica)
    #expect(!onFirst.isWorkerHere && onSecond.isWorkerHere)
    #expect(onFirst.jobs == onSecond.jobs && onSecond.jobs.value?.map(\.job) == [job])
  }

  @Test func shouldReadTheBacklogUnavailableWhenTheJobDerivationFaults() async throws {
    let (_, store) = try World.store()
    try await World.request(try World.key(), in: store)
    try await designate(mac, in: store)
    _ = try await store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT OR REPLACE INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'probe')",
        arguments: [JobEntry.databaseTableName, ProjectionFaults.wholeDerivation])
    }
    let read = try await backlog(at: 0, in: store)
    #expect(read.jobs.isUnavailable && read.changesAt == nil && read.worker.device?.replica == mac)
    #expect(try await placements([try World.key().ref], at: 0, in: store).placements.isUnavailable)
  }

  @Test func shouldQueueEveryKindButThePlanForTheWorker() {
    #expect(NovelJobKind.allCases.filter(\.queuesForWorker) == [.generate, .review, .finalizeReview, .canonRefresh])
  }

  private func requested(_ job: EntityRef, in store: VaultStore) async throws -> HLCTimestamp? {
    try await Projection.fetch(JobEntryDerivation.request(for: job), in: store).first?.requested
  }

  private func latest(_ job: EntityRef, in store: VaultStore) async throws -> JobLatestAttempt? {
    try await Projection.fetch(JobEntryDerivation.request(for: job), in: store).first?.latest
  }
}

private struct PlacementFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) { self.description = description }
}
