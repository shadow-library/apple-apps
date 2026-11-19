import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func store() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  try await write(store) { transaction in
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
    for chapter in 1...3 { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(contract()), in: &transaction) }
  }
  return store
}

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

@discardableResult
private func judge(_ store: VaultStore, chapter: Int = 1, _ findings: [ReviewFinding], verdict: String = "contradiction", pass: Bool = false) async throws -> UUID {
  let id = UUID()
  try await write(store) { transaction in
    try ReviewWrites.judge(novel: novel, chapter: chapter, findings: findings, verdict: verdict, generationPass: pass, id: id, in: &transaction)
  }
  return id
}

private func remedy(_ store: VaultStore, _ review: UUID, _ finding: String, _ action: ReviewRemedyAction?) async throws {
  try await write(store) { transaction in try ReviewWrites.remedy(novel: novel, review: review, finding: finding, action, in: &transaction) }
}

private func entry(_ store: VaultStore, _ chapter: Int = 1) async throws -> ChapterLifecycleEntry? {
  try await ChapterTables.lifecycle(novel, in: store)[chapter]
}

private func review(_ store: VaultStore, _ chapter: Int = 1) async throws -> DraftReviewState? {
  try await entry(store, chapter)?.review
}

private func approved(_ store: VaultStore) async throws -> UUID {
  let approval = UUID()
  try await write(store) { transaction in
    try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &transaction)
  }
  return approval
}

@Suite("Chapter lifecycle: generating and contradiction", TestTimeLimit.standard)
struct LifecycleReviewTests {
  // generation.service.ts:242-243 counts pending and in-progress jobs alike; persistDraft sets generating over an approval and revokes its reveals
  // (chapter-generation.graph.ts:184, 197).
  @Test func shouldShowAChapterGeneratingWhileItsGenerateJobIsOpenAndGiveItsApprovalBackWhenTheJobEnds() async throws {
    let store = try await store()
    let approval = try await approved(store)
    let job = try await Projection.write(store) { transaction in try ReviewWrites.requestGeneration(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await review(store) == .generating)
    #expect(try await entry(store)?.approval == nil)
    #expect(try await ChapterTables.approvals(novel, in: store).isEmpty)
    try await write(store) { transaction in try ReviewWrites.cancel(job, in: &transaction) }
    #expect(try await review(store) == .approved)
    #expect(try await ChapterTables.approvals(novel, in: store) == [1: approval])
  }

  @Test func shouldEndGeneratingWhenTheJobSucceedsAndShowAPlannedChapterWithoutADraftGenerating() async throws {
    let store = try await store()
    let attempt = try ReviewWrites.attempt(7)
    let job = try await Projection.write(store) { transaction in try ReviewWrites.requestGeneration(novel: novel, chapter: 2, in: &transaction) }
    #expect(try await review(store, 2) == .generating)
    #expect(try await entry(store, 2)?.draft == nil)
    try await write(store) { transaction in try ReviewWrites.succeed(job, attempt: attempt, in: &transaction) }
    #expect(try await review(store, 2) == nil)
  }

  // chapter-finalization.graph.ts:183 and persistDraft's setWhere (chapter-generation.graph.ts:190): nothing writes over a final draft.
  @Test func shouldKeepAFinalChapterFinalWhileAGenerateJobForItIsOpen() async throws {
    let store = try await store()
    _ = try await approved(store)
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in try ReviewWrites.requestGeneration(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await review(store) == .final)
  }

  // chapter-review.service.ts:498-520: an open blocking finding on the latest judge review of the text as it stands holds the draft, and revokes its approval.
  @Test func shouldHoldAnApprovedDraftAsAContradictionWhenALaterJudgeReviewOfItsHeadBlocks() async throws {
    let store = try await store()
    _ = try await approved(store)
    let id = try await judge(store, [ReviewWrites.finding("f1")])
    let held = try #require(try await entry(store))
    #expect(held.review == .contradiction && held.approval == nil && held.judge == id && held.openBlocking == 1)
    #expect(try await ChapterTables.approvals(novel, in: store).isEmpty)
  }

  @Test func shouldLiftAContradictionWhenTheBlockingFindingIsDismissedAndHoldItAgainWhenTheAnswerIsWithdrawn() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    let id = try await judge(store, [ReviewWrites.finding("f1"), ReviewWrites.finding("f2", .warning)])
    #expect(try await review(store) == .contradiction)
    try await remedy(store, id, "f1", .fixingMyself)
    #expect(try await review(store) == .contradiction)
    try await remedy(store, id, "f1", .dismissed)
    #expect(try await review(store) == .needsReview)
    #expect(try await entry(store)?.openBlocking == 0)
    try await remedy(store, id, "f1", nil)
    #expect(try await review(store) == .contradiction)
  }

  // review-records.ts:151-157: only the latest judge review gates, and only while it read the text as it stands.
  @Test func shouldGateOnlyOnTheLatestJudgeReviewOfTheHead() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await judge(store, [ReviewWrites.finding("f1")])
    let clear = try await judge(store, [], verdict: "consistent")
    #expect(try await review(store) == .needsReview)
    #expect(try await entry(store)?.judge == clear)
    try await judge(store, [ReviewWrites.finding("f1")])
    #expect(try await review(store) == .contradiction)
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "The tide turns back.", in: &transaction) }
    let moved = try #require(try await entry(store))
    #expect(moved.review == .needsReview && moved.judge == nil && moved.openBlocking == 0)
  }

  @Test func shouldNotHoldTheHeadOnAReviewOfOtherTextOrOfAnEditorialKind() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in
      try ReviewWrites.judge(novel: novel, chapter: 1, findings: [ReviewWrites.finding("f1")], body: "Other text.", in: &transaction)
    }
    #expect(try await review(store) == .needsReview)
    #expect(try await entry(store)?.judge == nil)
    try await write(store) { transaction in
      let head = try ChapterWrites.head(novel: novel, chapter: 1, in: transaction)
      let review = try ChapterReviewRecord(
        novel: novel, chapter: 1, reviewKind: .known(.editorial), draftRevision: head, bodyHash: hashReviewedBody("The tide turns."), disposition: .known(.blocking),
        findings: [ReviewWrites.finding("e1")])
      _ = try review.append(in: &transaction)
    }
    #expect(try await review(store) == .needsReview)
  }

  // chapter-review.service.ts:508-513: answering the findings of a review that held an approved draft lifts it to needs review, never back to approved.
  @Test func shouldKeepAnApprovalOutOfForceAfterTheReviewThatHeldItIsAnsweredUntilTheDraftIsApprovedAgain() async throws {
    let store = try await store()
    _ = try await approved(store)
    let id = try await judge(store, [ReviewWrites.finding("f1")])
    try await remedy(store, id, "f1", .dismissed)
    let lifted = try #require(try await entry(store))
    #expect(lifted.review == .needsReview && lifted.approval == nil && lifted.openBlocking == 0)
    let again = UUID()
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: again, in: &transaction) }
    #expect(try await entry(store)?.approval == again)
    #expect(try await review(store) == .approved)
  }

  // review-records.ts:47-72 records a generation pass without the gate, and setOpenDraftReview skips an approved draft (chapter-generation.graph.ts:226).
  @Test func shouldNeverRevokeAnApprovalOnAGenerationPassOnceItsFindingIsAnswered() async throws {
    let store = try await store()
    let approval = try await approved(store)
    let id = try await judge(store, [ReviewWrites.finding("f1")], pass: true)
    #expect(try await review(store) == .contradiction)
    try await remedy(store, id, "f1", .dismissed)
    #expect(try await entry(store)?.approval == approval)
    #expect(try await review(store) == .approved)
  }

  @Test func shouldKeepAnApprovalInForceWhenABlockingReviewReadOtherTextUnderTheHeadsRevision() async throws {
    let store = try await store()
    let approval = try await approved(store)
    try await write(store) { transaction in
      try ReviewWrites.judge(novel: novel, chapter: 1, findings: [ReviewWrites.finding("f1")], body: "Other text.", in: &transaction)
    }
    let kept = try #require(try await entry(store))
    #expect(kept.approval == approval && kept.review == .approved && kept.judge == nil)
  }

  // chapter-review.service.ts:470-478: a remedy carried onto the review before it is stored means the review never held the draft.
  @Test func shouldKeepAnApprovalInForceWhenTheReviewsBlockingFindingCarriedAnAnswer() async throws {
    let store = try await store()
    let approval = try await approved(store)
    try await write(store) { transaction in
      let id = UUID()
      try ReviewWrites.remedy(novel: novel, review: id, finding: "f1", .overridden, in: &transaction)
      try ReviewWrites.judge(novel: novel, chapter: 1, findings: [ReviewWrites.finding("f1")], id: id, in: &transaction)
    }
    #expect(try await entry(store)?.approval == approval)
    #expect(try await review(store) == .approved)
  }

  // generation.service.ts:505: approving answers every open blocking finding with an override, which lifts the hold.
  @Test func shouldStayHeldWhenApprovedWithoutOverridesAndApproveOnceTheFindingIsOverridden() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    let id = try await judge(store, [ReviewWrites.finding("f1")])
    let approval = UUID()
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &transaction) }
    #expect(try await review(store) == .contradiction)
    try await remedy(store, id, "f1", .overridden)
    #expect(try await entry(store)?.approval == approval)
    #expect(try await review(store) == .approved)
  }

  // chapter-generation.graph.ts:259-266, 890-902: a generation pass the route held stays held though nothing in it blocks, until an answer re-runs the gate.
  @Test func shouldHoldAGenerationPassThatEndedInReviewUntilOneOfItsFindingsIsAnswered() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    let id = try await judge(store, [ReviewWrites.finding("b1", .warning, .brief)], verdict: "consistent", pass: true)
    let held = try #require(try await entry(store))
    #expect(held.review == .contradiction && held.openBlocking == 0)
    try await remedy(store, id, "b1", .dismissed)
    #expect(try await review(store) == .needsReview)
  }

  @Test func shouldApproveAHeldGenerationPassWhenTheApprovalComesAfterIt() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await judge(store, [], verdict: "evaluation_failed", pass: true)
    #expect(try await review(store) == .contradiction)
    let approval = UUID()
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &transaction) }
    #expect(try await entry(store)?.approval == approval)
    #expect(try await review(store) == .approved)
  }

  // A consistent verdict accepts the pass (chapter-generation.graph.ts:266, 886) though a hard continuity finding is stored as blocking; finalize still sees it.
  @Test func shouldAcceptAConsistentGenerationPassWhoseFindingsTheRouteIgnoresAndStillCountItsBlockingFinding() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await judge(
      store, [ReviewWrites.finding("c1"), ReviewWrites.finding("r1", .warning, .readability), ReviewWrites.finding("m1", .note, .mechanics)], verdict: "consistent",
      pass: true)
    let accepted = try #require(try await entry(store))
    #expect(accepted.review == .needsReview && accepted.openBlocking == 1)
  }

  // persistDraft sets generating over a contradiction (chapter-generation.graph.ts:184), and the gate skips a generating draft (chapter-review.service.ts:535).
  @Test func shouldShowGeneratingOverAContradiction() async throws {
    let store = try await store()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await judge(store, [ReviewWrites.finding("f1")])
    try await write(store) { transaction in try ReviewWrites.requestGeneration(novel: novel, chapter: 1, in: &transaction) }
    let generating = try #require(try await entry(store))
    #expect(generating.review == .generating && generating.approval == nil && generating.openBlocking == 1)
  }

  @Test func shouldNotStaleALaterChapterWhenAnEarlierOneIsHeld() async throws {
    let store = try await store()
    _ = try await approved(store)
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction) }
    try await judge(store, [ReviewWrites.finding("f1")])
    #expect(try await review(store) == .contradiction)
    #expect(try await entry(store, 2)?.stale == nil)
  }
}
