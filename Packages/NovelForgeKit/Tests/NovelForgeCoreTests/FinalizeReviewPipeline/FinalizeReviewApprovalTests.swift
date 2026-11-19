import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// apps/novel-forge-server/src/modules/generation/generation.service.ts:457-512: approving requests the revision's finalize review, answers the open blocking
/// findings and is refused while the chapter generates.
@Suite("Finalize review on approval", TestTimeLimit.standard)
struct FinalizeReviewApprovalTests {
  @Test func shouldRequestTheFinalizeReviewOfTheApprovedRevisionOnceForTheSameProseAndPlan() async throws {
    let world = try await FinalizeReviewWorld()
    let revision = try await world.draft()
    let job = try await world.approve()
    let snapshot = try #require(try await snapshot(world, job))
    let key = snapshot.job.request.key
    let plan = try await planRevision(world)
    let input = FinalizeReviewJobInput(revision: revision, body: FinalizeReviewScript.prose, plan: plan)
    #expect(key.kind == NovelJobKind.finalizeReview.rawValue && key.target == NovelJobAddress.target(chapter: 1) && key.run == 1)
    #expect(key.fingerprint == input.fingerprint && snapshot.job.request.payload == input.json && snapshot.job.request.replica == world.store.replica)
    #expect(try await world.approve() == job)
    try await world.draft("\(FinalizeReviewScript.prose) Again.")
    #expect(try await world.approve() != job)
  }

  @Test func shouldRequestTheNextRunWhenTheApprovedRevisionsReviewWasCancelled() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.draft()
    let job = try await world.approve()
    let engine = try world.engine()
    #expect(try await engine.cancel(job: job) == .requested)
    let next = try await world.approve()
    #expect(next != job)
    #expect(try await snapshot(world, next)?.job.request.key.run == 2)
  }

  // finalize-review-stage.ts:31-38: the plan the revision was approved under binds the review, and so does the exact prose.
  @Test func shouldRequestAnotherFinalizeReviewWhenThePlanHeadOrTheRevisionChanges() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.draft()
    let first = try await world.approve()
    let novel = world.novel
    try await Projection.write(world.store) { transaction in
      var plan = PlanEdit(body: "Mira climbs the tower at dusk.")
      plan.knowledge = .set(PlanKnowledge(pov: ["mira"], learns: []))
      _ = try ChapterPlans.write(novel: novel, chapter: 1, plan, in: &transaction)
    }
    let replanned = try await world.approve()
    #expect(replanned != first)
    let (kept, replannedRun) = (try await snapshot(world, first), try await snapshot(world, replanned)?.job.request.key.run)
    #expect(kept != nil && replannedRun == 1)
    try await world.draft(summary: "Mira climbs the cold tower.")
    let resummarized = try await world.approve()
    #expect(resummarized != replanned && resummarized != first)
    let payload = try #require(try await snapshot(world, resummarized)).job.request.payload
    let input = try #require(FinalizeReviewJobInput(json: payload))
    let head = try await world.head()
    #expect(input.sourceHash == hashReviewedBody(FinalizeReviewScript.prose) && input.revision == head)
  }

  // finalize-review-stage.ts:55-60: approving again over a read that failed prepares it again.
  @Test func shouldPrepareAFailedReadAgainWhenTheSameRevisionIsApprovedAgain() async throws {
    let world = try await FinalizeReviewWorld(replies: [[.failure(.invalidRequest("refused"))], FinalizeReviewScript.reply()])
    let engine = try world.engine()
    try await world.draft()
    let failed = try await world.approve()
    guard case .settled(.failed) = try await world.run(engine, failed) else { throw EngineFixtureError(description: "the read did not fail") }
    let again = try await world.approve()
    let run = try await snapshot(world, again)?.job.request.key.run
    #expect(again != failed && run == 2)
    #expect(try await world.approve() == again)
    #expect(try await world.run(engine, again) == .settled(.succeeded))
    #expect(try await world.reviews().count == 1)
  }

  // generation.service.ts:482: the approval's write skips a draft that is generating, and the refusal reads as a conflict (draft-write-guard.ts:20).
  @Test func shouldRefuseToApproveWhileTheLifecycleReadsTheChapterGeneratingFromItsOpenGenerateJob() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let engine = try world.engine()
    let generate = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "g:1"))
    let novel = world.novel
    let review = { @Sendable () async throws -> DraftReviewState? in
      try await world.store.read { transaction in try ChapterLifecycleEntry.read(novel: novel, chapter: 1, in: transaction.database)?.review }
    }
    #expect(try await review() == .generating)
    await #expect(throws: DomainError.draftConflict(chapter: 1, head: head)) { try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head) }
    #expect(try await world.store.finalizeReviewJob(novel: world.novel, chapter: 1) == nil)
    _ = try await engine.cancel(job: generate.ref)
    #expect(try await review() == .needsReview)
    try await world.approve()
    #expect(try await review() == .approved)
  }

  // review-records.ts:151-182
  @Test func shouldOverrideTheBlockingFindingsStillOpenOnTheLatestJudgeReviewOfTheApprovedText() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let review = try await judge(world, revision: head, body: FinalizeReviewScript.prose)
    let novel = world.novel
    try await Projection.write(world.store) { transaction in
      _ = try ReviewRemedyRecord.set(novel: novel, review: review, finding: "dismissed", ReviewRemedy(action: .known(.dismissed), fingerprint: "f-dismissed"), in: &transaction)
      _ = try ReviewRemedyRecord.set(novel: novel, review: review, finding: "mine", ReviewRemedy(action: .known(.fixingMyself), fingerprint: "f-mine"), in: &transaction)
    }
    try await world.approve()
    let remedies = try await remedies(world, review: review)
    #expect(remedies["open"] == ReviewRemedy(action: .known(.overridden), fingerprint: "f-open", reason: "approved by the author"))
    #expect(remedies["mine"] == ReviewRemedy(action: .known(.overridden), fingerprint: "f-mine", reason: "approved by the author"))
    #expect(remedies["dismissed"] == ReviewRemedy(action: .known(.dismissed), fingerprint: "f-dismissed"))
    #expect(remedies["warning"] == nil)
  }

  @Test func shouldLeaveTheFindingsAloneWhenTheLatestJudgeReviewReadOtherText() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let current = try await judge(world, revision: head, body: FinalizeReviewScript.prose)
    let stale = try await judge(world, revision: head, body: "Other text.")
    try await world.approve()
    #expect(try await remedies(world, review: current).isEmpty)
    #expect(try await remedies(world, review: stale).isEmpty)
  }

  // The lifecycle gates on the latest readable judge review (ChapterLifecycleReviews.swift), so approving answers that one and the chapter reads approved.
  @Test func shouldOverrideTheReviewTheLifecycleGatesOnWhenALaterJudgeReviewCannotBeRead() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let readable = try await judge(world, revision: head, body: FinalizeReviewScript.prose)
    let novel = world.novel
    try await Projection.write(world.store) { transaction in
      _ = try transaction.append(NovelForgeKey.chapterReview(UUID()), item: ["novel": novel.json, "chapter": 1, "kind": "judge", "draft_revision": .string(head)])
    }
    let lifecycle = { @Sendable () async throws -> ChapterLifecycleEntry? in
      try await world.store.read { transaction in try ChapterLifecycleEntry.read(novel: novel, chapter: 1, in: transaction.database) }
    }
    #expect(try await lifecycle()?.review == .contradiction)
    let approval = try await world.store.approveChapter(novel: novel, chapter: 1, revision: head).id
    #expect(try await remedies(world, review: readable)["open"]?.action == .known(.overridden))
    let entry = try await lifecycle()
    #expect(entry?.review == .approved && entry?.approval == approval)
  }

  // finalize-review.service.ts:564-578 over stored reads and the job's state.
  @Test func shouldTellWhyTheReviewCannotBeAnsweredYet() async throws {
    let world = try await FinalizeReviewWorld(replies: [[.failure(.invalidRequest("refused"))]])
    let (store, novel) = (world.store, world.novel)
    let decide = { () async throws(FinalizeAnswerError) in _ = try await store.keepRoutineFinalizeItems(novel: novel, chapter: 1) }
    try await world.draft()
    await world.expectRefusal("FRV_001", decide)
    let job = try await world.approve()
    await world.expectRefusal("FRV_002", decide)
    guard case .settled(.failed) = try await world.run(try world.engine(), job) else { throw EngineFixtureError(description: "the read did not fail") }
    await world.expectRefusal("FRV_003", decide)
    try await world.draft("\(FinalizeReviewScript.prose) Again.")
    await world.expectRefusal("FRV_001", decide)
  }

  @Test func shouldRefuseAnswersOnceTheChapterIsFinal() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    try await world.prepared(on: try world.engine(finalizing: FinalizeReviewPipeline.commit))
    let (store, novel) = (world.store, world.novel)
    #expect(try await store.writeDomain { transaction throws(DomainError) in try transaction.isFinal(novel: novel, chapter: 1) })
    await world.expectRefusal("FRV_011") { () throws(FinalizeAnswerError) in
      try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "appearance:mira", decision: .kept)
    }
  }

  private func judge(_ world: FinalizeReviewWorld, revision: String, body: String) async throws -> UUID {
    let findings = [
      ReviewFinding(id: "open", severity: .known(.blocking), category: .known(.continuity), text: "Open.", fingerprint: "f-open"),
      ReviewFinding(id: "mine", severity: .known(.blocking), category: .known(.continuity), text: "Mine.", fingerprint: "f-mine"),
      ReviewFinding(id: "dismissed", severity: .known(.blocking), category: .known(.continuity), text: "Dismissed.", fingerprint: "f-dismissed"),
      ReviewFinding(id: "warning", severity: .known(.warning), category: .known(.continuity), text: "Warning.", fingerprint: "f-warning"),
    ]
    let review = try ChapterReviewRecord(
      novel: world.novel, chapter: 1, reviewKind: .known(.judge), draftRevision: revision, bodyHash: hashReviewedBody(body), disposition: .known(.blocking),
      findings: findings)
    try await Projection.write(world.store) { transaction in _ = try review.append(in: &transaction) }
    return review.id
  }

  private func remedies(_ world: FinalizeReviewWorld, review: UUID) async throws -> [String: ReviewRemedy] {
    let novel = world.novel
    return try await world.store.read { transaction in
      var remedies = [String: ReviewRemedy]()
      for finding in ["open", "mine", "dismissed", "warning"] {
        if case .readable(let entry) = try ReviewRemedyRecord.read(novel: novel, review: review, finding: finding, in: transaction) { remedies[finding] = entry.record.remedy }
      }
      return remedies
    }
  }

  private func snapshot(_ world: FinalizeReviewWorld, _ job: EntityRef) async throws -> JobSnapshot? {
    try await world.store.read { transaction in try JobSnapshot.load(job, in: transaction) }
  }

  private func planRevision(_ world: FinalizeReviewWorld) async throws -> String? {
    let novel = world.novel
    return try await world.store.read { transaction in
      guard case .revisioned(let state)? = try transaction.state(of: try ChapterPlanRecord.ref(novel: novel, chapter: 1)) else { return nil }
      return state.headRevision
    }
  }
}
