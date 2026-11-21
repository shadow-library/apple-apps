import Foundation
import NovelForgeCore
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForge

private struct ChecksCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    guard let origin = URL(string: "https://api.anthropic.com") else { return nil }
    return ProviderCredential(origin: origin, secret: "sk-test")
  }
}

@MainActor
private struct ChecksWorld {
  let store: VaultStore
  let novel: UUID
  let engine: JobEngine
  let model: ChecksModel

  static func make(draft: String? = "The tide came in. It went out again. Nobody watched it go.") async throws -> ChecksWorld {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in try Library.create(NewNovel(title: "Ashfall"), in: &transaction) }
    if let draft {
      _ = try await store.write { transaction in try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: draft), base: nil, at: Date(), in: &transaction) }
    }
    let origin = try #require(URL(string: "https://api.anthropic.com"))
    let binding = try #require(ProviderBinding(origin: origin, provider: ScriptedModelProvider(calls: [])))
    let consent = ConsentDisclosure.novelText
    let host = binding.host
    try await store.write { transaction in
      try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.id, atMillis: 1, in: &transaction)
    }
    let engine = try JobEngine(
      store: store,
      router: { requestGuard in
        TaskRouter(
          configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: binding, openRouter: nil, credentials: ChecksCredentials(), store: store,
          requestGuard: requestGuard)
      }, consent: consent.requirement, clock: LeaseClock(trusted: nil))
    return ChecksWorld(store: store, novel: novel, engine: engine, model: ChecksModel(context: NovelContext(store: store, novel: novel), chapter: 1))
  }

  func requester(handles: HandleBox = HandleBox(), startsHere: Bool = true) -> ChecksModel.Requester {
    ChecksModel.requester(store: store, novel: novel, chapter: 1, engine: engine, startsHere: startsHere) { handles.handles.append($0) }
  }

  func run(_ kind: ChapterReviewKind, handles: HandleBox = HandleBox()) async {
    await model.run(kind, pace: nil, runsJobs: true, using: requester(handles: handles))
    for handle in handles.handles { _ = await handle.result }
  }

  func appendFindings(to base: ChapterReviewRecord) async throws {
    let record = try ChapterReviewRecord(
      novel: novel, chapter: 1, reviewKind: .known(.judge), draftRevision: base.draftRevision, bodyHash: base.bodyHash, disposition: .known(.blocking),
      findings: [
        ReviewFinding(
          id: "block", severity: .known(.blocking), category: .known(.continuity), text: "Mara already left the harbour.", evidence: "Nobody watched it go.",
          fingerprint: "fp-block"),
        ReviewFinding(id: "warn", severity: .known(.warning), category: .known(.brief), text: "The plan asks for a storm.", fingerprint: "fp-warn"),
      ], checked: ["continuity with the Story Bible"])
    _ = try await store.write { transaction in try record.append(in: &transaction) }
    await model.load()
  }

  func judgeReview() async throws -> ChapterReviewView {
    await run(.readability)
    let base = try #require(model.latest(.readability)).review
    try await appendFindings(to: base)
    return try #require(model.latest(.judge))
  }
}

@MainActor
private final class HandleBox {
  var handles: [JobRunHandle] = []
}

@MainActor
@Suite("Checks model")
struct ChecksModelTests {
  @Test func shouldRunMechanicsAndReadabilityAtOnceWithoutAJob() async throws {
    let world = try await ChecksWorld.make()

    await world.model.run(.mechanics, pace: nil, runsJobs: false, using: world.requester())
    await world.model.run(.readability, pace: nil, runsJobs: false, using: world.requester())

    #expect(world.model.refusal == nil)
    #expect(world.model.latest(.mechanics) != nil)
    #expect(world.model.latest(.readability) != nil)
    #expect(world.model.latest(.judge) == nil)
  }

  @Test func shouldRequestJudgeAndEditorialReviewsAsJobs() async throws {
    let world = try await ChecksWorld.make()
    let handles = HandleBox()

    await world.run(.judge, handles: handles)
    await world.run(.editorial, handles: handles)

    let jobs = try await world.store.load(ChapterJobs.self, ChapterJobsQuery(novel: world.novel, chapter: 1, now: LeaseClock(trusted: nil).now()))
    #expect(jobs.latest(.review) != nil)
    #expect(world.model.refusal == nil)
    #expect(handles.handles.count == 2)
    #expect(world.model.starting == nil)
  }

  @Test func shouldOnlyRequestAJudgeReviewWhereThisDeviceLeavesItToTheWorkerAndAnswerQuickKindsAtOnce() async throws {
    let world = try await ChecksWorld.make()
    let handles = HandleBox()

    await world.model.run(.judge, pace: nil, runsJobs: true, using: world.requester(handles: handles, startsHere: false))
    await world.model.run(.mechanics, pace: nil, runsJobs: true, using: world.requester(handles: handles, startsHere: false))

    let jobs = try await world.store.load(ChapterJobs.self, ChapterJobsQuery(novel: world.novel, chapter: 1, now: LeaseClock(trusted: nil).now()))
    let judge = try #require(jobs.latest(review: .judge))
    #expect(judge.status == .queued && judge.latest == nil && handles.handles.isEmpty)
    #expect(world.model.refusal == nil && !world.model.elsewhere && world.model.latest(.mechanics) != nil)
  }

  @Test func shouldRefuseAJobKindWhereThisCopyRunsNoJobs() async throws {
    let world = try await ChecksWorld.make()

    await world.model.run(.judge, pace: nil, runsJobs: false, using: world.requester())

    #expect(world.model.refusal == JobsErrors.notRunningHere)
  }

  @Test func shouldListAFindingWithItsSeverityCategoryAndEvidence() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()

    let finding = try #require(review.review.findings.first)
    #expect(review.openFindings == 2)
    #expect(review.openBlocking == 1)
    #expect(ChecksDisplay.severityLabel(finding.severity) == "Blocking")
    #expect(ChecksDisplay.categoryLabel(finding.category) == "Continuity")
    #expect(finding.evidence == "Nobody watched it go.")
    #expect(ChecksDisplay.groups(review.review.findings).map { ChecksDisplay.groupLabel($0.severity, count: $0.findings.count) } == ["Blocking · 1", "Warnings · 1"])
    #expect(ChecksDisplay.status(review, job: nil).label == "1 blocking")
  }

  @Test func shouldSetAndClearARemedy() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()
    let warning = try #require(review.review.findings.last)

    #expect(await world.model.answer(review, finding: warning, action: .dismissed, reason: "deliberate"))
    let dismissed = try #require(world.model.latest(.judge))
    #expect(dismissed.remedies["warn"]?.action == .known(.dismissed))
    #expect(dismissed.remedies["warn"]?.reason == "deliberate")
    #expect(dismissed.openFindings == 1)
    #expect(ChecksDisplay.state(dismissed.remedies["warn"]) == .settled)

    #expect(await world.model.clear(dismissed, finding: warning))
    let cleared = try #require(world.model.latest(.judge))
    #expect(cleared.remedies["warn"] == nil)
    #expect(cleared.openFindings == 2)
  }

  @Test func shouldKeepAFixMyselfAnswerOpen() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()
    let blocking = try #require(review.review.findings.first)

    #expect(await world.model.answer(review, finding: blocking, action: .fixingMyself, reason: nil))

    let answered = try #require(world.model.latest(.judge))
    #expect(ChecksDisplay.state(answered.remedies["block"]) == .fixing)
    #expect(answered.openBlocking == 1)
  }

  @Test func shouldOverrideOnlyABlockingFindingAndDismissOnlyWithAReason() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()
    let (blocking, warning) = (review.review.findings[0], review.review.findings[1])

    #expect(await world.model.answer(review, finding: warning, action: .overridden, reason: nil) == false)
    #expect(world.model.refusal?.headline == "Only a blocking finding can be overridden.")
    #expect(await world.model.answer(review, finding: blocking, action: .dismissed, reason: "  ") == false)
    #expect(world.model.refusal?.headline == "Say why you are dismissing this finding.")
    #expect(await world.model.answer(review, finding: blocking, action: .overridden, reason: nil))
    #expect(world.model.refusal == nil)
    #expect(try #require(world.model.latest(.judge)).openBlocking == 0)
  }

  @Test func shouldFlagAReviewStaleOnceTheChapterChangesAndRefuseItsAnswers() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()
    #expect(review.stale == false)
    let (store, novel) = (world.store, world.novel)
    _ = try await store.write { transaction in
      try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "A different tide came in."), base: nil, at: Date(), in: &transaction)
    }

    await world.model.load()

    let stale = try #require(world.model.latest(.judge))
    #expect(stale.stale)
    #expect(ChecksDisplay.status(stale, job: nil).label == "Out of date")
    #expect(ChecksDisplay.subline(stale) == "Reviewed an earlier version")
    #expect(await world.model.answer(stale, finding: stale.review.findings[0], action: .fixingMyself, reason: nil) == false)
    #expect(world.model.refusal?.headline == ChecksErrors.headline(code: "REV_003"))
  }

  @Test func shouldSayAChapterWithNoProseHasNothingToReview() async throws {
    let world = try await ChecksWorld.make(draft: nil)

    await world.model.run(.mechanics, pace: nil, runsJobs: true, using: world.requester())

    #expect(world.model.refusal == PresentedError(headline: "This chapter has no prose to review yet.", detail: "REV_006"))
  }

  @Test func shouldSayAChapterBeingWrittenCannotBeReviewed() async throws {
    let world = try await ChecksWorld.make()
    _ = try await world.engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "checks-test"))

    await world.model.run(.readability, pace: nil, runsJobs: true, using: world.requester())

    #expect(world.model.refusal == PresentedError(headline: "This chapter is still being written. Review it once the draft is ready.", detail: "REV_007"))
  }

  @Test func shouldGiveEveryReviewCodeAHeadline() {
    let codes = ["REV_001", "REV_002", "REV_003", "REV_004", "REV_005", "REV_006", "REV_007"]
    #expect(codes.allSatisfy { ChecksErrors.headline(code: $0) != nil })
    #expect(ChecksErrors.headline(code: "REV_999") == nil)
  }

  @Test func shouldReadEachReviewKindsJobAsQueuedOrRunningOnItsOwn() async throws {
    let world = try await ChecksWorld.make()
    let judge = try await world.engine.request(NovelJobRequest(kind: .review, novel: world.novel, chapter: 1, fingerprint: "checks-judge", payload: ["kind": "judge"])).ref
    _ = try await world.engine.request(NovelJobRequest(kind: .review, novel: world.novel, chapter: 1, fingerprint: "checks-editorial", payload: ["kind": "editorial"]))
    let clock = LeaseClock(trusted: nil)

    func lines() async throws -> [ChapterJobLine] {
      let query = ChapterJobBoardQuery(novel: world.novel, chapter: 1, replica: world.store.replica, now: clock.now())
      let board = try await world.store.load(ChapterJobBoard.self, query)
      return ChapterWorkspaceStatus(row: nil, board: board, replica: world.store.replica, standing: JobsStanding(here: .running, platform: .mac)).lines
    }

    var current = try await lines()
    #expect(ChecksDisplay.phase(current, of: .judge) == .queued)
    #expect(ChecksDisplay.phase(current, of: .editorial) == .queued)
    #expect(ChecksDisplay.phase(current, of: .mechanics) == nil)
    let now = clock.now()
    let start = AttemptStart(job: judge, replica: world.store.replica, started: now, byHand: false, pinned: .null)
    let id = try AttemptID(UUID.v7(at: now.date))
    _ = try await world.store.write { transaction in try AttemptRecords.start(id, start, step: nil, in: &transaction) }
    current = try await lines()
    #expect(ChecksDisplay.phase(current, of: .judge) == .running)
    #expect(ChecksDisplay.phase(current, of: .editorial) == .queued)
    #expect(ChecksDisplay.status(nil, job: .running).label == "Reviewing…")
  }

  @Test func shouldDecideWhoCanAnswerAndWhenUndoAsksFirst() async throws {
    let world = try await ChecksWorld.make()
    let review = try await world.judgeReview()
    let (blocking, warning) = (review.review.findings[0], review.review.findings[1])
    let settled = ReviewRemedy(action: .known(.overridden), fingerprint: "fp-block", reason: nil)
    let fixing = ReviewRemedy(action: .known(.fixingMyself), fingerprint: "fp-block", reason: nil)

    #expect(ChecksDisplay.offersOverride(blocking))
    #expect(!ChecksDisplay.offersOverride(warning))
    #expect(ChecksDisplay.isAnswerable(review))
    #expect(ChecksDisplay.confirmsUndo(approved: true, kind: .judge, finding: blocking, remedy: settled))
    #expect(!ChecksDisplay.confirmsUndo(approved: false, kind: .judge, finding: blocking, remedy: settled))
    #expect(!ChecksDisplay.confirmsUndo(approved: true, kind: .editorial, finding: blocking, remedy: settled))
    #expect(!ChecksDisplay.confirmsUndo(approved: true, kind: .judge, finding: warning, remedy: settled))
    #expect(!ChecksDisplay.confirmsUndo(approved: true, kind: .judge, finding: blocking, remedy: fixing))

    let (store, novel) = (world.store, world.novel)
    _ = try await store.write { transaction in try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "Another tide."), base: nil, at: Date(), in: &transaction) }
    await world.model.load()
    #expect(!ChecksDisplay.isAnswerable(try #require(world.model.latest(.judge))))
  }

  @Test func shouldReloadAFinalChapterAfterASameLengthAmend() {
    let (first, second) = (
      ChapterContent.Body.final(.init(title: nil, body: "abcd", note: nil, amended: false)), ChapterContent.Body.final(.init(title: nil, body: "abce", note: nil, amended: true))
    )

    #expect(ChecksSheet.reloadToken(first) != ChecksSheet.reloadToken(second))
    #expect(ChecksSheet.reloadToken(first) == ChecksSheet.reloadToken(first))
  }
}
