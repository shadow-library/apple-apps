import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync
import Synchronization
import Testing

@testable import NovelForge

/// Engine calls that record what the runtime asks for and refuse every start; `stopped` is what `interruptedRuns` lists, and a held start waits for `open`.
private final class FakeEngine: Sendable {
  private struct State {
    var runs: [EntityRef] = []
    var resumes: [EntityRef] = []
    var resumedAtLaunch = 0
    var settled = 0
    var listings = 0
    var stopped: [InterruptedJobRun] = []
    var holding = false
    var held: CheckedContinuation<Void, Never>?
  }

  private let state = Mutex(State())
  private let resumeRefusal: @Sendable (EntityRef) -> JobEngineError

  init(holdingTheFirstStart: Bool = false, resumeRefusal: @escaping @Sendable (EntityRef) -> JobEngineError = { _ in .pipelineNotYetAvailable(.generate) }) {
    self.resumeRefusal = resumeRefusal
    state.withLock { $0.holding = holdingTheFirstStart }
  }

  var runs: [EntityRef] { state.withLock { $0.runs } }
  var resumes: [EntityRef] { state.withLock { $0.resumes } }
  var resumedAtLaunch: Int { state.withLock { $0.resumedAtLaunch } }
  var settled: Int { state.withLock { $0.settled } }
  var listings: Int { state.withLock { $0.listings } }
  var isHolding: Bool { state.withLock { $0.held != nil } }

  func stop(_ run: InterruptedJobRun) { state.withLock { $0.stopped.append(run) } }

  func open() {
    let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.holding = false
      defer { state.held = nil }
      return state.held
    }
    held?.resume()
  }

  var calls: JobEngineCalls {
    JobEngineCalls(
      run: { [self] _, job throws(JobEngineError) in
        let holds = state.withLock { state -> Bool in
          state.runs.append(job)
          return state.holding && state.runs.count == 1
        }
        if holds { await hold() }
        throw .pipelineNotYetAvailable(.generate)
      },
      resumeHere: { [self] _, job throws(JobEngineError) in
        state.withLock { $0.resumes.append(job) }
        throw resumeRefusal(job)
      },
      resumeInterrupted: { [self] _ throws(JobEngineError) in
        state.withLock { $0.resumedAtLaunch += 1 }
        return []
      },
      settleStopped: { [self] _ throws(JobEngineError) in
        state.withLock { $0.settled += 1 }
        return []
      },
      interruptedRuns: { [self] _ throws(JobEngineError) in
        state.withLock { state in
          state.listings += 1
          return state.stopped
        }
      })
  }

  private func hold() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let resume = state.withLock { state -> Bool in
        guard state.holding else { return true }
        state.held = continuation
        return false
      }
      if resume { continuation.resume() }
    }
  }
}

/// A vault with one novel and a runtime on the given kind of device whose engine calls are fake; jobs are requested by writing their records, so any
/// replica can be the one that asked.
@MainActor
private struct PlacementWorld {
  nonisolated static let mac = ReplicaID(UUID(uuidString: "0192d5a0-0000-7000-8000-00000000000a") ?? UUID())

  let store: VaultStore
  let novel: UUID
  let fake: FakeEngine
  let runtime: JobRuntime

  static func make(_ platform: JobPlatform, fake: FakeEngine = FakeEngine()) async throws -> PlacementWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    let services = AIServices.novelForge(defaults: try #require(UserDefaults(suiteName: "JobsPlacementTests-\(UUID().uuidString)")))
    let clock = LeaseClock(trusted: nil)
    let runtime = JobRuntime(store: store, clock: clock, platform: platform, takeOverDelay: .milliseconds(20), calls: fake.calls) { () throws(JobEngineError) in
      try JobEngine(
        store: store, router: { requestGuard in await services.router(store: store, requestGuard: requestGuard) }, consent: ConsentDisclosure.novelText.requirement,
        clock: clock)
    }
    return PlacementWorld(store: store, novel: novel, fake: fake, runtime: runtime)
  }

  @discardableResult
  func request(_ kind: NovelJobKind, chapter: Int = 1, by replica: ReplicaID? = nil) async throws -> EntityRef {
    let key = try JobKey(
      scope: NovelJobAddress.scope(of: novel), kind: kind.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: UUID().uuidString, run: 1)
    let request = JobRequest(key: key, payload: .null, replica: replica ?? store.replica)
    return try await store.write { transaction in try JobRecords.request(request, in: &transaction) }.job.ref
  }

  func designate(_ worker: ReplicaID?) async throws {
    let now = runtime.clock.now()
    _ = try await store.write { transaction in
      try ReplicaDirectory.declareActive(Self.mac, name: "Studio Mac", platform: "macOS", createdMillis: 1, in: &transaction)
      return try WorkerRecords.designate(worker, at: now, in: &transaction)
    }
  }

  /// An attempt of `replica` whose lease was granted `ago` and so runs out `LeaseTerms.duration` after that.
  @discardableResult
  func startAttempt(of job: EntityRef, by replica: ReplicaID, ago: TimeInterval, step: AttemptStep? = AttemptStep(name: "draft", index: 1)) async throws -> AttemptID {
    let started = LeaseInstant(date: Date().addingTimeInterval(-ago), source: .device)
    let id = try AttemptID(UUID.v7(at: started.date))
    let start = AttemptStart(job: job, replica: replica, started: started, byHand: false, pinned: .null)
    _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: step, in: &transaction) }
    return id
  }

  func stopped(_ job: EntityRef, attempt: AttemptID) -> InterruptedJobRun {
    InterruptedJobRun(attempt: attempt, job: job, target: NovelJobTarget(novel: novel, chapter: 1, kind: .generate), step: AttemptStep(name: "draft", index: 1))
  }

  /// Long enough for a drain that would start a job to have started it.
  func settle() async throws {
    try await Task.sleep(for: .milliseconds(300))
  }
}

@MainActor
@Suite("Job placement", TestTimeLimit.standard)
struct JobsPlacementTests {
  @Test func shouldPlaceEachKindByDeviceAndWorker() {
    let (here, other) = (ReplicaID(UUID.v7()), ReplicaID(UUID.v7()))
    let named = { (replica: ReplicaID) in VaultWorker.named(JobDevice(replica: replica, name: "Studio Mac", isHere: replica == here)) }
    let table: [(JobPlatform, VaultWorker, drains: Bool, ownGeneration: Bool, othersLapsedGeneration: Bool, ownPlan: Bool)] = [
      (.mac, named(here), true, true, true, true),
      (.mac, named(other), false, true, false, true),
      (.mac, .none, false, true, false, true),
      (.mac, .unreadable("newer"), false, true, false, true),
      (.mac, .retired(other), false, true, false, true),
      (.phone, named(here), false, false, false, true),
      (.phone, named(other), false, false, false, true),
      (.phone, .none, false, false, false, true),
    ]
    for (platform, worker, drains, ownGeneration, othersLapsedGeneration, ownPlan) in table {
      let policy = JobPlacementPolicy(platform: platform, worker: worker, here: here)
      #expect(policy.drainsWorkerBacklog == drains, "\(platform) \(worker)")
      #expect(policy.startsAutomatically(.generate, requester: here, started: false) == ownGeneration, "\(platform) \(worker)")
      #expect(policy.startsAutomatically(.generate, requester: other, started: true) == othersLapsedGeneration, "\(platform) \(worker)")
      #expect(policy.startsAutomatically(.plan, requester: here, started: false) == ownPlan, "\(platform) \(worker)")
      #expect(!policy.startsAutomatically(.plan, requester: other, started: false), "\(platform) \(worker)")
    }
  }

  @Test func shouldSayWhoAQueuedJobWaitsForAsThisDeviceSeesIt() {
    let (here, other) = (ReplicaID(UUID.v7()), ReplicaID(UUID.v7()))
    let studio = JobDevice(replica: other, name: "Studio Mac", isHere: false)
    let phone = JobPlacementPolicy(platform: .phone, worker: .named(studio), here: here)
    #expect(phone.waiting(for: .generate, requester: here, started: false, on: .worker(.named(studio))) == .worker("Studio Mac"))
    #expect(phone.waiting(for: .generate, requester: here, started: false, on: .worker(.none)) == .noWorker)
    #expect(phone.waiting(for: .generate, requester: here, started: false, on: .worker(.retired(other))) == .noWorker)
    #expect(phone.waiting(for: .generate, requester: here, started: false, on: .worker(.unreadable("newer"))) == .worker(nil))
    let selfNamed = JobDevice(replica: here, name: "iPhone", isHere: true)
    #expect(phone.waiting(for: .generate, requester: here, started: false, on: .worker(.named(selfNamed))) == .noWorker)
    #expect(phone.waiting(for: .plan, requester: here, started: false, on: .requester(selfNamed)) == .here)
    #expect(phone.waiting(for: .plan, requester: here, started: true, on: .requester(selfNamed)) == .you)
    #expect(phone.waiting(for: .plan, requester: other, started: false, on: .requester(studio)) == .requester("Studio Mac"))
    let mac = JobPlacementPolicy(platform: .mac, worker: .named(studio), here: here)
    #expect(mac.waiting(for: .generate, requester: here, started: false, on: .worker(.named(studio))) == .here)
    #expect(mac.waiting(for: .generate, requester: other, started: false, on: .worker(.named(studio))) == .worker("Studio Mac"))
  }

  @Test func shouldResumeNothingAtAPhonesLaunchButSettleAndListWhatItCanResume() async throws {
    let world = try await PlacementWorld.make(.phone)
    let job = try await world.request(.generate)
    world.fake.stop(world.stopped(job, attempt: try AttemptID(UUID.v7())))

    await world.runtime.launch()

    #expect(world.fake.resumedAtLaunch == 0 && world.fake.settled == 1 && world.fake.resumes.isEmpty)
    #expect(world.runtime.resumable[job] != nil && world.runtime.standing.resumable == [job])
    try await world.settle()
    #expect(world.fake.runs.isEmpty && world.fake.resumes.isEmpty)
  }

  @Test func shouldResumeAtAMacsLaunchWithoutSettlingFirst() async throws {
    let world = try await PlacementWorld.make(.mac)
    await world.runtime.launch()
    #expect(world.fake.resumedAtLaunch == 1 && world.fake.settled == 0 && world.fake.listings >= 1)
  }

  @Test func shouldStartOnlyItsOwnPlansOnAPhoneEvenWhenTheRecordNamesIt() async throws {
    let world = try await PlacementWorld.make(.phone)
    try await world.designate(world.store.replica)
    let plan = try await world.request(.plan)
    try await world.request(.generate)
    try await world.request(.review, by: PlacementWorld.mac)
    try await world.request(.plan, chapter: 2, by: PlacementWorld.mac)

    await world.runtime.launch()

    try await JobsWait.until("the plan starts") { world.fake.runs.contains(plan) }
    try await world.settle()
    #expect(world.fake.runs == [plan])
  }

  @Test func shouldRunItsOwnRequestsOfEveryKindOnAMacThatIsNotTheWorker() async throws {
    let world = try await PlacementWorld.make(.mac)
    try await world.designate(PlacementWorld.mac)
    let generation = try await world.request(.generate)
    let plan = try await world.request(.plan, chapter: 2)
    try await world.request(.review, by: PlacementWorld.mac)

    await world.runtime.launch()

    try await JobsWait.until("both own jobs start") { world.fake.runs.count >= 2 }
    try await world.settle()
    #expect(world.fake.runs == [generation, plan])
  }

  @Test func shouldDrainTheVaultsWorkerBacklogOnTheWorkerMac() async throws {
    let world = try await PlacementWorld.make(.mac)
    try await world.designate(world.store.replica)
    let plan = try await world.request(.plan)
    let review = try await world.request(.review, by: PlacementWorld.mac)
    let generation = try await world.request(.generate)
    try await world.request(.plan, chapter: 2, by: PlacementWorld.mac)

    await world.runtime.launch()

    try await JobsWait.until("the backlog is drained") { world.fake.runs.count >= 3 }
    try await world.settle()
    #expect(world.fake.runs == [plan, review, generation])
  }

  @Test func shouldResumeItsOwnLapsedRunInTheWorkerBacklogRatherThanStartAnotherAttempt() async throws {
    let world = try await PlacementWorld.make(.mac)
    try await world.designate(world.store.replica)
    let job = try await world.request(.generate, by: PlacementWorld.mac)
    let attempt = try await world.startAttempt(of: job, by: world.store.replica, ago: 400)
    world.fake.stop(world.stopped(job, attempt: attempt))

    await world.runtime.launch()

    try await JobsWait.until("the stopped run is resumed") { world.fake.resumes == [job] }
    try await world.settle()
    #expect(world.fake.runs.isEmpty)
  }

  @Test func shouldStartALapsedJobAfreshOnceNothingIsLeftOfItsRunToResume() async throws {
    let world = try await PlacementWorld.make(.mac, fake: FakeEngine(resumeRefusal: { .nothingToResume($0) }))
    try await world.designate(world.store.replica)
    let job = try await world.request(.generate, by: PlacementWorld.mac)
    let attempt = try await world.startAttempt(of: job, by: world.store.replica, ago: 400)
    world.fake.stop(world.stopped(job, attempt: attempt))

    await world.runtime.launch()

    try await JobsWait.until("the job starts once resuming finds nothing") { world.fake.runs == [job] }
    #expect(world.fake.resumes == [job])
  }

  @Test func shouldSkipWhatTheWorkerNoLongerTakesOnceTheJobBeforeItEnds() async throws {
    let world = try await PlacementWorld.make(.mac, fake: FakeEngine(holdingTheFirstStart: true))
    try await world.designate(world.store.replica)
    let first = try await world.request(.generate, by: PlacementWorld.mac)
    try await world.request(.review, by: PlacementWorld.mac)
    await world.runtime.launch()
    try await JobsWait.until("the first start is held") { world.fake.isHolding }

    try await world.designate(PlacementWorld.mac)
    world.fake.open()

    try await world.settle()
    #expect(world.fake.runs == [first])
  }

  @Test func shouldReadNothingAgainOnceShutDownWhileAStartWasHeld() async throws {
    let world = try await PlacementWorld.make(.mac, fake: FakeEngine(holdingTheFirstStart: true))
    try await world.designate(world.store.replica)
    let first = try await world.request(.generate, by: PlacementWorld.mac)
    let lapsing = try await world.request(.review, by: PlacementWorld.mac)
    try await world.startAttempt(of: lapsing, by: PlacementWorld.mac, ago: 359.4)
    await world.runtime.launch()
    try await JobsWait.until("the first start is held") { world.fake.isHolding }

    world.runtime.shutDown()
    world.fake.open()

    try await Task.sleep(for: .milliseconds(1500))
    #expect(world.fake.runs == [first])
  }

  @Test func shouldReadTheBacklogAgainWhenALeaseLapsesWithNoWrite() async throws {
    let world = try await PlacementWorld.make(.mac)
    try await world.designate(world.store.replica)
    let job = try await world.request(.generate, by: PlacementWorld.mac)
    try await world.startAttempt(of: job, by: PlacementWorld.mac, ago: 359.4)

    await world.runtime.launch()
    #expect(world.fake.runs.isEmpty)

    try await JobsWait.until("the job starts once the other device's lease lapses") { world.fake.runs == [job] }
  }

  @Test func shouldNameTheDeviceWhoseLiveRunRefusedResume() async throws {
    let (unnamed, live) = (ReplicaID(UUID.v7()), try AttemptID(UUID.v7()))
    let fake = FakeEngine(resumeRefusal: { _ in .runningElsewhere(live, PlacementWorld.mac) })
    let world = try await PlacementWorld.make(.phone, fake: fake)
    try await world.designate(nil)
    let job = try await world.request(.generate)
    await world.runtime.launch()
    let listed = world.fake.listings

    let refused = try #require(await world.runtime.resume(job))

    #expect(refused.headline == String(localized: "\("Studio Mac") is running this job now. It goes on there.", table: "Jobs"))
    #expect(refused.detail == "job_engine.running_elsewhere" && world.fake.listings > listed)
    let generic = JobsErrors.presented(.runningElsewhere(live, unnamed), holder: nil)
    #expect(generic.headline == String(localized: "Another device is running this job.", table: "Jobs"))
  }
}
