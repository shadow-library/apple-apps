import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowSync
import Testing

@testable import NovelForge

@MainActor
@Suite("Chapter workspace status")
struct JobsStatusTests {
  @Test func shouldShowAGenerationThisMacStartsAsWaitingToStartWithRunHereAndCancelOnlyWhereJobsRun() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()

    let here = try await world.status(.mac)
    #expect(here.status == .generating(nil))
    let line = try #require(here.lines.first)
    let wait = try #require(line.wait)
    #expect(line.job == job && wait.starter == .here && wait.stopped == nil && line.actions == [.runHere, .cancel])
    let requested = try #require(wait.requested)
    #expect(abs(requested.timeIntervalSinceNow) < 60)
    let now = Date()
    #expect(
      JobDisplay.summary(line, now: now)
        == "\(String(localized: "Waiting to start", table: "Jobs")) · \(String(localized: "requested \(JobDisplay.relative(requested, now: now))", table: "Jobs"))")
    #expect(try await world.status(.mac, here: .elsewhere).lines.map(\.actions) == [[]])
  }

  @Test func shouldSayNoMacRunsJobsOnAPhoneAndOfferRunHereWhateverConsentWaitsFor() async throws {
    let world = try await StatusWorld.make()
    _ = try await world.requestGeneration()

    let line = try #require(try await world.status(.phone, consentNeeded: true).lines.first)

    #expect(line.wait?.starter == .noWorker && line.actions == [.runHere, .cancel])
    #expect(JobDisplay.summary(line, now: Date()).hasPrefix(String(localized: "No Mac runs jobs", table: "Jobs")))
  }

  @Test func shouldAskForConsentOnlyForAJobThisDeviceStartsItself() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let consenting = try await world.status(.mac, consentNeeded: true)
    #expect(consenting.lines == [ChapterJobLine(job: job, kind: .generate, state: .waitingForConsent, actions: [.allow, .cancel])])
  }

  @Test func shouldNameTheWorkerAJobWaitsForButNeverOnTheMacThatAskedForIt() async throws {
    let world = try await StatusWorld.make()
    try await world.name(StatusWorld.studio, "Studio Mac", asWorker: true)
    _ = try await world.requestGeneration()
    _ = try await world.requestGeneration(by: StatusWorld.studio, chapter: 2, fingerprint: "studio")

    #expect(try await world.status(.phone).lines.compactMap(\.wait).map(\.starter) == [.worker("Studio Mac")])
    #expect(try await world.status(.mac).lines.compactMap(\.wait).map(\.starter) == [.here])
    #expect(try await world.status(.mac, chapter: 2).lines.compactMap(\.wait).map(\.starter) == [.worker("Studio Mac")])
    let line = try #require(try await world.status(.phone).lines.first)
    #expect(JobDisplay.summary(line, now: Date()).hasPrefix(String(localized: "Waiting for \("Studio Mac")", table: "Jobs")))
  }

  @Test func shouldSayNoMacRunsJobsOnAPhoneTheWorkerRecordNames() async throws {
    let world = try await StatusWorld.make()
    try await world.name(world.store.replica, "iPhone", asWorker: true)
    _ = try await world.requestGeneration()
    #expect(try await world.status(.phone).lines.compactMap(\.wait).map(\.starter) == [.noWorker])
  }

  @Test func shouldNameTheDeviceRunningAJobWithItsStepAndRenewal() async throws {
    let world = try await StatusWorld.make()
    try await world.name(StatusWorld.studio, "Studio Mac", asWorker: false)
    let job = try await world.requestGeneration()
    let step = AttemptStep(name: "draft", index: 1)
    try await world.startAttempt(of: job, by: StatusWorld.studio, step: step)

    let status = try await world.status(.phone)
    #expect(status.status == .generating(step))
    let line = try #require(status.lines.first)
    guard case .runningOnAnotherDevice(let elsewhere) = line.state else {
      Issue.record("the job should run on another device")
      return
    }
    #expect(elsewhere.device == "Studio Mac" && elsewhere.step == step && line.actions == [.cancel])
    let (now, renewed) = (Date(), try #require(elsewhere.renewed))
    let expected = [
      String(localized: "Running on \("Studio Mac")", table: "Jobs"), String(localized: "Step 2 · Drafting", table: "Jobs"),
      String(localized: "updated \(JobDisplay.relative(renewed, now: now))", table: "Jobs"),
    ]
    #expect(JobDisplay.summary(line, now: now) == expected.joined(separator: " · "))
  }

  @Test func shouldCallAnUnnamedDeviceAnotherDevice() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    try await world.startAttempt(of: job, by: ReplicaID(UUID.v7()), step: nil)
    let line = try #require(try await world.status(.mac).lines.first)
    #expect(JobDisplay.summary(line, now: Date()).hasPrefix(String(localized: "Running on another device", table: "Jobs")))
  }

  @Test func shouldOfferResumeForARunStoppedHereOnlyWhileTheEngineListsIt() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let step = AttemptStep(name: "draft", index: 1)
    try await world.startAttempt(of: job, by: world.store.replica, step: step, ago: 400)

    let listed = try #require(try await world.status(.phone, resumable: [job]).lines.first)
    guard case .interrupted(let stop) = listed.state else {
      Issue.record("the run should read as interrupted here")
      return
    }
    #expect(stop.step == step && !stop.released && stop.at != nil && listed.actions == [.resume, .cancel])
    let now = Date()
    let expected = [
      String(localized: "Interrupted on this device", table: "Jobs"), String(localized: "Step 2 · Drafting", table: "Jobs"),
      String(localized: "last updated \(JobDisplay.relative(try #require(stop.at), now: now))", table: "Jobs"),
    ]
    #expect(JobDisplay.summary(listed, now: now) == expected.joined(separator: " · "))

    let unlisted = try #require(try await world.status(.phone).lines.first)
    #expect(unlisted.wait?.stopped?.step == step && unlisted.wait?.starter == .noWorker && unlisted.actions == [.runHere, .cancel])
  }

  @Test func shouldOfferResumeForAPhonesOwnLiveLeaseOnceTheEngineListsItsRunAsStopped() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let step = AttemptStep(name: "draft", index: 1)
    try await world.startAttempt(of: job, by: world.store.replica, step: step)

    let relaunched = try #require(try await world.status(.phone, resumable: [job]).lines.first)
    guard case .interrupted(let stop) = relaunched.state else {
      Issue.record("a run the engine lists as stopped should read as interrupted")
      return
    }
    #expect(stop.step == step && !stop.released && stop.at != nil && relaunched.actions == [.resume, .cancel])
    #expect(try await world.status(.phone).lines.map(\.state) == [.runningHere(step)])
    #expect(try await world.status(.phone, here: .starting, resumable: [job]).lines.map(\.state) == [.resumingHere(step)])
  }

  @Test func shouldReadAReleasedLeaseAsTheTimeTheRunStopped() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let attempt = try await world.startAttempt(of: job, by: world.store.replica, step: AttemptStep(name: "draft", index: 1))
    let released = try await world.release(attempt)

    let line = try #require(try await world.status(.phone, resumable: [job]).lines.first)

    #expect(line.state == .interrupted(JobStop(step: AttemptStep(name: "draft", index: 1), at: released, released: true)))
    #expect(JobDisplay.summary(line, now: Date()).hasSuffix(String(localized: "stopped at \(JobDisplay.clockTime(released, now: Date()))", table: "Jobs")))
  }

  @Test func shouldShowThisDevicesLeaseAsAnotherCopysWhereThisCopyRunsNoJobs() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    try await world.startAttempt(of: job, by: world.store.replica, step: nil)

    #expect(try await world.status(.mac).lines.map(\.state) == [.runningHere(nil)])
    #expect(try await world.status(.mac, here: .elsewhere).lines == [ChapterJobLine(job: job, kind: .generate, state: .runningInAnotherCopy(nil), actions: [])])
  }

  @Test func shouldLabelThisDevicesRunByWhetherThisCopyRunsStartsOrLeavesJobs() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let step = AttemptStep(name: "judge", index: 6)
    try await world.startAttempt(of: job, by: world.store.replica, step: step)

    #expect(try await world.status(.mac).lines.map(\.state) == [.runningHere(step)])
    #expect(try await world.status(.mac, here: .starting).lines == [ChapterJobLine(job: job, kind: .generate, state: .resumingHere(step), actions: [])])
    #expect(try await world.status(.mac, here: .elsewhere).lines.map(\.state) == [.runningInAnotherCopy(step)])
    #expect(try await world.status(.mac, here: .unavailable).lines == [ChapterJobLine(job: job, kind: .generate, state: .startedOnThisDevice(step), actions: [])])
  }

  @Test func shouldOfferTryAgainForAFailedJobOfAnyKind() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let failure = AttemptFailure(code: "model.server", message: "The provider failed.")
    try await world.fail(try await world.startAttempt(of: job, by: world.store.replica, step: nil), failure)

    let status = try await world.status(.phone)
    #expect(status.lines == [ChapterJobLine(job: job, kind: .generate, state: .failed(failure), actions: [.tryAgain])])
    #expect(try await world.status(.mac, here: .elsewhere).lines.map(\.actions) == [[]])
    #expect(JobsErrors.failure(failure) == String(localized: "Couldn't reach the model. Try again shortly.", table: "Jobs"))
  }

  @Test func shouldLabelEveryStatusWithTheReferencesChipAndIntent() {
    let step = AttemptStep(name: "draft", index: 1)
    let table: [(ChapterStatus, String, String)] = [
      (.drafting, "Draft", "neutral"), (.generating(nil), "Generating", "info"), (.generating(step), "Generating · Step 2 · Drafting", "info"),
      (.needsReview, "Needs review", "warning"), (.contradiction, "Conflict", "danger"), (.approved, "Approved", "success"), (.finalizing, "Finalizing", "info"),
      (.final, "Final", "success"),
    ]
    for (status, label, intent) in table {
      let chip = JobDisplay.chip(status)
      #expect(chip.label == label && String(describing: chip.intent) == intent, "\(status)")
    }
  }

  @Test func shouldReadAChapterWithNoLifecycleRowAsADraftAndKeepCancelledJobsOut() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    _ = try await world.engine.cancel(job: job)

    let status = try await world.status(.mac)
    #expect(status.lines.isEmpty && !status.jobsUnavailable)
    #expect(ChapterWorkspaceStatus(row: nil, jobs: nil, placements: nil, replica: world.store.replica, standing: .starting).status == .drafting)
  }
}

extension ChapterJobLine {
  fileprivate var wait: JobWait? {
    guard case .queued(let wait) = state else { return nil }
    return wait
  }
}

/// A vault with chapter 1 drafted and a job engine no runtime drains, so requested jobs stay queued.
@MainActor
private struct StatusWorld {
  static let studio = ReplicaID(UUID(uuidString: "0192d5a0-0000-7000-8000-0000000000b1") ?? UUID())

  let store: VaultStore
  let novel: UUID
  let engine: JobEngine
  let clock = LeaseClock(trusted: nil)

  static func make() async throws -> StatusWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    _ = try await store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "The tide came in."), base: nil, at: Date(), in: &transaction)
    }
    let services = AIServices.novelForge(defaults: try #require(UserDefaults(suiteName: "JobsStatusTests-\(UUID().uuidString)")))
    let engine = try JobEngine(
      store: store, router: { requestGuard in await services.router(store: store, requestGuard: requestGuard) }, consent: ConsentDisclosure.novelText.requirement,
      clock: LeaseClock(trusted: nil))
    return StatusWorld(store: store, novel: novel, engine: engine)
  }

  func requestGeneration(by replica: ReplicaID? = nil, chapter: Int = 1, fingerprint: String = "status-test") async throws -> EntityRef {
    guard let replica else { return try await engine.request(NovelJobRequest(kind: .generate, novel: novel, chapter: chapter, fingerprint: fingerprint)).ref }
    let key = try JobKey(
      scope: NovelJobAddress.scope(of: novel), kind: NovelJobKind.generate.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: fingerprint,
      run: 1)
    let request = JobRequest(key: key, payload: .null, replica: replica)
    return try await store.write { transaction in try JobRecords.request(request, in: &transaction) }.job.ref
  }

  func name(_ replica: ReplicaID, _ name: String, asWorker: Bool) async throws {
    let now = clock.now()
    _ = try await store.write { transaction in
      try ReplicaDirectory.declareActive(replica, name: name, platform: "macOS", createdMillis: 1, in: &transaction)
      if asWorker { _ = try WorkerRecords.designate(replica, at: now, in: &transaction) }
    }
  }

  @discardableResult
  func startAttempt(of job: EntityRef, by replica: ReplicaID, step: AttemptStep?, ago: TimeInterval = 0) async throws -> AttemptID {
    let now = LeaseInstant(date: Date().addingTimeInterval(-ago), source: .device)
    let start = AttemptStart(job: job, replica: replica, started: now, byHand: false, pinned: .null)
    let id = try AttemptID(UUID.v7(at: now.date))
    _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: step, in: &transaction) }
    return id
  }

  /// Releases this device's lease now, as an interrupt that lets another device take the job over does; answers the release time.
  func release(_ attempt: AttemptID) async throws -> Date {
    let (replica, now) = (store.replica, clock.now())
    _ = try await store.write { transaction in try AttemptRecords.update(attempt, AttemptUpdate(lease: .released(at: now)), by: replica, in: &transaction) }
    return now.date
  }

  func fail(_ attempt: AttemptID, _ failure: AttemptFailure) async throws {
    let replica = store.replica
    _ = try await store.write { transaction in try AttemptRecords.update(attempt, AttemptUpdate(settlement: .failed(failure)), by: replica, in: &transaction) }
  }

  func status(
    _ platform: JobPlatform, chapter: Int = 1, here: JobsHere = .running, consentNeeded: Bool = false, resumable: Set<EntityRef> = []
  ) async throws -> ChapterWorkspaceStatus {
    let row = try await store.load(ChapterList.self, novel).rows.value?.first { $0.chapter == chapter }
    let board = try await store.load(ChapterJobBoard.self, ChapterJobBoardQuery(novel: novel, chapter: chapter, replica: store.replica, now: clock.now()))
    let standing = JobsStanding(here: here, platform: platform, consentNeeded: consentNeeded, resumable: resumable)
    return ChapterWorkspaceStatus(row: row, board: board, replica: store.replica, standing: standing)
  }
}
