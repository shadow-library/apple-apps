import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

/// apps/novel-forge-server/tests/ai/commit-final-prose.spec.ts over chapter-finalization.graph.ts:127-207, with the review gate of finalize-review-gate.ts:143-155.
@Suite("Finalize commit (commit-final-prose.spec.ts)", TestTimeLimit.standard)
struct FinalizeCommitSpecTests {
  private func approvedWithRead(_ book: ChapterBook, learns: [KnowledgeReveal] = [reveal("mara", "heir")]) async throws -> (head: String, approval: UUID) {
    try await book.plan(1, learns: learns)
    let head = try await book.draft(1)
    let approval = try await book.approve(1)
    try await book.reviewRead(1)
    return (head, approval)
  }

  // commit-final-prose.spec.ts:29 and :41-56: the canon binds the approved head finalize read, with that head's own summary
  @Test func shouldMarkFinalOnlyTheApprovedHeadAtTheRevisionFinalizeRead() async throws {
    let book = try await ChapterBook.make()
    let (head, approval) = try await approvedWithRead(book)
    #expect(try await book.run(book.commit(1)) == 1)
    let canon = try #require(try await book.final(1)).canon
    #expect(canon.draftRevision == head && canon.approval == approval && canon.summary == "It turns.")
    #expect(try await book.view(1)?.review == .final)
    #expect(canon.review?.id == (try await book.reads(1).first?.id))
  }

  // commit-final-prose.spec.ts:58 (chapter-finalization.graph.ts:175): the knowledge the approval ledgered at the finalized revision is committed and frozen
  @Test func shouldCommitTheProvisionalKnowledgeBoundToTheFinalizedRevision() async throws {
    let book = try await ChapterBook.make()
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store).isEmpty)
    _ = try await approvedWithRead(book)
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .provisional)])
    try await book.run(book.commit(1))
    #expect(try await book.final(1)?.canon.knowledge == [reveal("mara", "heir")])
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
  }

  // commit-final-prose.spec.ts:73 and :106: the commit landed once; finalizing again finds the chapter final and writes nothing more
  @Test func shouldCommitOnceAndRefuseASecondCommitOfTheFinalChapter() async throws {
    let book = try await ChapterBook.make()
    _ = try await approvedWithRead(book)
    try await book.run(book.commit(1))
    let canon = try await book.final(1)
    await book.expect(.draftFinal(1), book.commit(1))
    #expect(try await book.final(1) == canon)
    #expect(try await book.refreshJobs().count == 1)
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
  }

  // commit-final-prose.spec.ts:81 and :91: a revision written after the approval is not what was approved, so nothing is committed
  @Test func shouldCommitNothingWhenTheDraftMovedPastTheApprovedRevision() async throws {
    let book = try await ChapterBook.make()
    _ = try await approvedWithRead(book)
    try await book.draft(1, "The tide turns twice.")
    await book.expect(.draftNotApproved(1), book.commit(1))
    #expect(try await book.final(1) == nil)
    #expect(try await book.refreshJobs().isEmpty)
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store).isEmpty)
  }

  // commit-final-prose.spec.ts:99: the approval no longer in force at the same revision (here, the plan's terms changed) rolls the commit back
  @Test func shouldCommitNothingWhenTheApprovalWasResetAtTheSameRevision() async throws {
    let book = try await ChapterBook.make()
    let (head, _) = try await approvedWithRead(book)
    try await book.plan(1, learns: [])
    #expect(try await book.head(1) == head)
    await book.expect(.draftNotApproved(1), book.commit(1))
    #expect(try await book.final(1) == nil)
  }
}

/// apps/novel-forge-server/tests/generation/finalize-gate.spec.ts (common/finalize-gate.ts:21-24), as the commit refuses (finalize-refusals.ts:40-41).
@Suite("Finalize gate (finalize-gate.spec.ts)", TestTimeLimit.standard)
struct FinalizeGateSpecTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let name: String
    let isolated: Bool
    let summary: String?
    let state: [String: JSONValue]?
    let refusal: DomainError?

    var testDescription: String { name }
  }

  static let ash: [String: JSONValue] = ["lastBeat": "Ash jumps"]

  static let cases = [
    Case(name: "spec :6 an isolated draft with a summary and a state", isolated: true, summary: "Ash fled the tower.", state: ash, refusal: nil),
    Case(name: "spec :11 an isolated draft without a summary", isolated: true, summary: nil, state: ash, refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :13 an isolated draft with an empty summary", isolated: true, summary: "", state: ash, refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :17 an isolated draft with a whitespace summary", isolated: true, summary: "   \n\t", state: ash, refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :21 an isolated draft without a state", isolated: true, summary: "Ash fled the tower.", state: nil, refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :26 an isolated draft with an empty state", isolated: true, summary: "Ash fled the tower.", state: [:], refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :30 an isolated draft missing both", isolated: true, summary: nil, state: nil, refusal: .isolatedWithoutSummary(1)),
    Case(name: "spec :34 a standard draft is never gated on its state", isolated: false, summary: "Ash fled the tower.", state: nil, refusal: nil),
    Case(name: "spec :35 a standard draft with an empty state", isolated: false, summary: "Ash fled the tower.", state: [:], refusal: nil),
    Case(name: "finalize-refusals.ts:41 a standard draft without a summary", isolated: false, summary: "", state: nil, refusal: .summaryMissing(1)),
  ]

  @Test(arguments: cases)
  func shouldGateTheDraftAsTheReference(_ gate: Case) async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1, body: "Ash jumps from the tower.", summary: gate.summary, isolated: gate.isolated, state: gate.state)
    try await book.approve(1)
    try await book.reviewRead(1)
    guard let refusal = gate.refusal else {
      #expect(try await book.run(book.commit(1)) == 1)
      return
    }
    await book.expect(refusal, book.commit(1))
    #expect(try await book.final(1) == nil)
  }
}

/// The commit's guards in order: the head is the approval's revision first (G06), then finalizeRefusals' order (finalize-refusals.ts:35-46) with the review
/// gate's own (finalize-review-gate.ts:47-59); each case carries every later refusal too, so the first is the one that surfaces.
@Suite("Finalize commit guards", TestTimeLimit.standard)
struct FinalizeCommitGuardTests {
  /// Chapter 2 drafted without a summary after chapter 1, which is not final, approved, its read not yet stored.
  private func book() async throws -> ChapterBook {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.save(2, "Two.", summary: " ", base: nil)
    try await book.approve(2)
    return book
  }

  private func head(_ book: ChapterBook) async throws -> String { try #require(try await book.head(2)) }

  @Test func shouldRefuseAHeadThatIsNotTheApprovedRevisionFirst() async throws {
    let book = try await book()
    try await book.save(2, "Two again.", summary: " ", base: nil)
    await book.expect(.draftNotApproved(2), book.commit(2))
  }

  @Test func shouldRefuseAnUnreadableJudgeReviewBeforeTheFinalizeReview() async throws {
    let book = try await book()
    let novel = book.novel
    let judge = ChapterReviewRecord.ref(UUID())
    try await book.run { transaction in
      _ = try transaction.append(judge, item: ["novel": novel.json, "chapter": .int(2), "kind": .string("judge"), "findings": .string("from a newer version")])
    }
    await book.expect(.unreadable(judge), book.commit(2))
  }

  @Test func shouldRefuseWhileTheApprovedHeadsReadIsStillToCome() async throws {
    let book = try await book()
    await book.expect(.finalizeRefused(.reviewPreparing(chapter: 2)), book.commit(2))
    #expect(DomainError.finalizeRefused(.reviewPreparing(chapter: 2)).code == "FRV_002")
  }

  // FinalizeReviewDecisions.openReview: every job asked to read the head ended without a review
  @Test func shouldRefuseAsFailedOnceEveryReadOfTheHeadEnded() async throws {
    let book = try await book()
    let job = try #require(try await book.store.finalizeReviewJob(novel: book.novel, chapter: 2))
    try await book.run { transaction in try ReviewWrites.cancel(job, in: &transaction) }
    await book.expect(.finalizeRefused(.reviewFailed), book.commit(2))
    #expect(DomainError.finalizeRefused(.reviewFailed).code == "FRV_003")
  }

  @Test func shouldRefuseAReadOfOtherProse() async throws {
    let book = try await book()
    let (novel, head) = (book.novel, try await head(book))
    try await book.run { transaction in
      let record = try FinalizeReviewRecord(
        attempt: try ReviewWrites.attempt(31), job: try JobWorld.key(novel: novel, chapter: 2, kind: .finalizeReview).ref.key, novel: novel, chapter: 2,
        draftRevision: head, sourceHash: hashReviewedBody("Other prose."), planHash: nil, isolated: false, items: [])
      _ = try record.append(in: &transaction)
    }
    await book.expect(.finalizeRefused(.proseChanged), book.commit(2))
  }

  @Test func shouldRefuseWhileAnItemIsUnanswered() async throws {
    let book = try await book()
    try await book.reviewRead(2, items: [ReviewItems.item(Kept.appearance("mara"))])
    await book.expect(.finalizeRefused(.unanswered(count: 1)), book.commit(2))
  }

  @Test func shouldRefuseAMilestoneLeftUnreachedThatAPlannedRevealNeeds() async throws {
    let book = try await book()
    try await book.reviewRead(2, items: [ReviewItems.item(Kept.milestone("rise", reached: false), dependents: ["heir"])])
    try await book.answer(2, item: Kept.milestone("rise", reached: false).itemKey, .kept)
    await book.expect(.finalizeRefused(.strandedReveal(milestone: "rise", facts: ["heir"])), book.commit(2))
  }

  @Test func shouldRefuseAnIsolatedChapterWithoutItsStateBeforeTheSummaryAndOrder() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.draft(2, body: "Two.", summary: "Two.", isolated: true, state: nil)
    try await book.approve(2)
    try await book.reviewRead(2)
    await book.expect(.isolatedWithoutSummary(2), book.commit(2))
  }

  @Test func shouldRefuseAMissingSummaryBeforeTheOrder() async throws {
    let book = try await book()
    try await book.reviewRead(2)
    await book.expect(.summaryMissing(2), book.commit(2))
  }

  @Test func shouldRefuseAChapterAfterOneThatIsNotFinalLast() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    try await book.draft(2)
    try await book.approve(2)
    try await book.reviewRead(2)
    await book.expect(.finalizeOutOfOrder(2), book.commit(2))
    try await book.approve(1)
    try await book.reviewRead(1)
    try await book.run(book.commit(1))
    #expect(try await book.run(book.commit(2)) == 2)
  }

  // Decision 12: approval settling a review never finalizes an isolated chapter; its author does
  @Test func shouldFinalizeAnIsolatedChapterOnlyForItsAuthor() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1, body: "Ash jumps.", summary: "Ash fled.", isolated: true, state: FinalizeGateSpecTests.ash)
    try await book.approve(1)
    try await book.reviewRead(1)
    await book.expect(.finalizeRefused(.isolatedByAuthorOnly(chapter: 1)), book.commit(1, by: .approval))
    #expect(try await book.run(book.commit(1, by: .author)) == 1)
  }
}
