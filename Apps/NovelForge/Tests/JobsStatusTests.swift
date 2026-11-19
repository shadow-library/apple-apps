import Foundation
import NovelForgeCore
import ShadowCore
import ShadowJobs
import ShadowStore
import Testing

@testable import NovelForge

@MainActor
@Suite("Chapter workspace status")
struct JobsStatusTests {
  @Test func shouldShowAQueuedGenerationWithRunHereAndCancelOnlyWhereJobsRun() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()

    let here = try await world.status(.running)
    #expect(here.status == .generating(nil))
    #expect(here.lines == [ChapterJobLine(job: job, kind: .generate, state: .queued, actions: [.runHere, .cancel])])
    #expect(try await world.status(.elsewhere).lines.map(\.actions) == [[]])
  }

  @Test func shouldShowAnotherDevicesLiveLeaseAsRunningThereWithoutRunHere() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let elsewhere = ReplicaID(UUID.v7())
    try await world.startAttempt(of: job, by: elsewhere, step: AttemptStep(name: "draft", index: 1))

    let status = try await world.status(.running)
    #expect(status.status == .generating(AttemptStep(name: "draft", index: 1)))
    #expect(status.lines == [ChapterJobLine(job: job, kind: .generate, state: .runningOnAnotherDevice(AttemptStep(name: "draft", index: 1)), actions: [.cancel])])
    #expect(JobDisplay.progress(.generate, AttemptStep(name: "draft", index: 1)) == String(localized: "Step 2 · Drafting", table: "Jobs"))
  }

  @Test func shouldShowThisDevicesLeaseAsAnotherCopysWhereThisCopyRunsNoJobs() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    try await world.startAttempt(of: job, by: world.store.replica, step: nil)

    #expect(try await world.status(.running).lines.map(\.state) == [.runningHere(nil)])
    #expect(try await world.status(.elsewhere).lines == [ChapterJobLine(job: job, kind: .generate, state: .runningInAnotherCopy(nil), actions: [])])
  }

  @Test func shouldLabelThisDevicesRunByWhetherThisCopyRunsStartsOrLeavesJobs() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let step = AttemptStep(name: "judge", index: 6)
    try await world.startAttempt(of: job, by: world.store.replica, step: step)

    #expect(try await world.status(.running).lines.map(\.state) == [.runningHere(step)])
    #expect(try await world.status(.starting).lines == [ChapterJobLine(job: job, kind: .generate, state: .resumingHere(step), actions: [])])
    #expect(try await world.status(.elsewhere).lines.map(\.state) == [.runningInAnotherCopy(step)])
    #expect(try await world.status(.unavailable).lines == [ChapterJobLine(job: job, kind: .generate, state: .startedOnThisDevice(step), actions: [])])
  }

  @Test func shouldAskForConsentInsteadOfRunHereWhileTheRuntimeWaitsForIt() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    #expect(try await world.status(.running, consentNeeded: true).lines == [ChapterJobLine(job: job, kind: .generate, state: .waitingForConsent, actions: [.allow, .cancel])])
  }

  @Test func shouldOfferTryAgainForAFailedJobOfAnyKind() async throws {
    let world = try await StatusWorld.make()
    let job = try await world.requestGeneration()
    let failure = AttemptFailure(code: "model.server", message: "The provider failed.")
    try await world.fail(try await world.startAttempt(of: job, by: world.store.replica, step: nil), failure)

    let status = try await world.status(.running)
    #expect(status.lines == [ChapterJobLine(job: job, kind: .generate, state: .failed(failure), actions: [.tryAgain])])
    #expect(try await world.status(.elsewhere).lines.map(\.actions) == [[]])
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

    let status = try await world.status(.running)
    #expect(status.lines.isEmpty && !status.jobsUnavailable)
    #expect(ChapterWorkspaceStatus(row: nil, jobs: nil, replica: world.store.replica, here: .running).status == .drafting)
  }
}

/// A vault with chapter 1 drafted and a job engine no runtime drains, so requested jobs stay queued.
@MainActor
private struct StatusWorld {
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
    let services = AIServices.live(defaults: try #require(UserDefaults(suiteName: "JobsStatusTests-\(UUID().uuidString)")))
    let engine = try JobEngine(
      store: store, router: { requestGuard in await services.router(store: store, requestGuard: requestGuard) }, consent: ConsentDisclosure.novelText.requirement,
      clock: LeaseClock(trusted: nil))
    return StatusWorld(store: store, novel: novel, engine: engine)
  }

  func requestGeneration() async throws -> EntityRef {
    try await engine.request(NovelJobRequest(kind: .generate, novel: novel, chapter: 1, fingerprint: "status-test")).ref
  }

  @discardableResult
  func startAttempt(of job: EntityRef, by replica: ReplicaID, step: AttemptStep?) async throws -> AttemptID {
    let now = clock.now()
    let start = AttemptStart(job: job, replica: replica, started: now, byHand: false, pinned: .null)
    let id = try AttemptID(UUID.v7(at: now.date))
    _ = try await store.write { transaction in try AttemptRecords.start(id, start, step: step, in: &transaction) }
    return id
  }

  func fail(_ attempt: AttemptID, _ failure: AttemptFailure) async throws {
    let replica = store.replica
    _ = try await store.write { transaction in try AttemptRecords.update(attempt, AttemptUpdate(settlement: .failed(failure)), by: replica, in: &transaction) }
  }

  func status(_ here: JobsHere, consentNeeded: Bool = false) async throws -> ChapterWorkspaceStatus {
    let row = try await store.load(ChapterList.self, novel).rows.value?.first { $0.chapter == 1 }
    let jobs = try await store.load(ChapterJobs.self, ChapterJobsQuery(novel: novel, chapter: 1, now: clock.now()))
    return ChapterWorkspaceStatus(row: row, jobs: jobs.jobs, replica: store.replica, here: here, consentNeeded: consentNeeded)
  }
}
