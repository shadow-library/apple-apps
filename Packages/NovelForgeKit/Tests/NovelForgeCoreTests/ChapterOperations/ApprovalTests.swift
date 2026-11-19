import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let rewritten = StaleCause.ancestorDraft(chapter: 1, change: .rewritten(source: DraftSource.handEdited.rawValue))

@Suite("Draft approval", TestTimeLimit.standard)
struct ApprovalTests {
  private func approving(_ book: ChapterBook, _ chapter: Int, revision: String, as intent: ApprovalIntent = .standard) -> BookWrite<UUID> {
    let (novel, requester) = (book.novel, book.store.replica)
    return { try ChapterApprovals.approve(novel: novel, chapter: chapter, revision: revision, as: intent, requester: requester, in: &$0) }
  }

  private func planRevision(_ book: ChapterBook, _ chapter: Int) async throws -> String? {
    let novel = book.novel
    return try await book.store.read { transaction in
      guard case .revisioned(let state)? = try transaction.state(of: try ChapterPlanRecord.ref(novel: novel, chapter: chapter)) else { return nil }
      return state.headRevision
    }
  }

  private func approvedMark(_ book: ChapterBook, _ chapter: Int) async throws -> String? {
    let novel = book.novel
    return try await book.store.read { try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: $0).history?.marks[.approved] }
  }

  /// Chapters 1 and 2 drafted, then chapter 1 rewritten, so chapter 2 is stale.
  private func staleSecond(_ book: ChapterBook) async throws {
    try await book.draft(1)
    try await book.draft(2)
    try await book.draft(1, "Rewritten.")
    #expect(try await book.lifecycle(2)?.stale == rewritten)
  }

  private func lockHeir(_ book: ChapterBook) async throws {
    let novel = book.novel
    try await book.run { try Secrets.upsert(novel: novel, secret: "heir", text: "The ledger is forged.", SecretChanges(revealChapter: .set(5)), in: &$0) }
  }

  @Test func shouldRecordTheRevisionAndPlanTermsTheAuthorApprovedAndMarkTheRevision() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1, learns: [reveal("mara", "heir")])
    let head = try await book.draft(1)
    let id = try await book.approve(1)
    let approval = try #require(try await book.approvals(1).first)
    let contract = try #require(try await book.planContent(1)?.contract)
    #expect(approval.id == id)
    #expect(approval.approvalKind == .known(.standard))
    #expect(approval.draftRevision == head)
    #expect(approval.planRevision == (try await planRevision(book, 1)))
    #expect(approval.planTermsDigest == ChapterFingerprint.planTerms(contract))
    #expect(approval.upstreamDigest == nil)
    #expect(try await book.view(1) == LifecycleView(review: .approved, approval: id))
    #expect(try await approvedMark(book, 1) == head)
    #expect(try await ChapterTables.knowledge(book.novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .provisional)])
  }

  @Test func shouldApproveAChapterWithoutAPlanUnderEmptyTerms() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    let id = try await book.approve(1)
    #expect(try await book.approvals(1).first?.planRevision == ChapterApprovals.planlessRevision)
    #expect(try await book.approvals(1).first?.planTermsDigest == ChapterFingerprint.planTerms(nil))
    #expect(try await book.view(1) == LifecycleView(review: .approved, approval: id))
  }

  @Test func shouldReturnTheApprovalInForceWithoutWritingAgain() async throws {
    let book = try await ChapterBook.make()
    try await book.draft(1)
    let first = try await book.approve(1)
    #expect(try await book.approve(1) == first)
    #expect(try await book.approvals(1).count == 1)
  }

  @Test func shouldRefuseAStaleDraftUnlessApprovedAsWrittenOverTheCauseTheAuthorSaw() async throws {
    let book = try await ChapterBook.make()
    try await staleSecond(book)
    let head = try #require(try await book.head(2))
    await book.expect(.draftStale(chapter: 2, reason: rewritten.reason), approving(book, 2, revision: head))
    await book.expect(.draftConflict(chapter: 2, head: head), approving(book, 2, revision: head, as: .asWritten(seen: .unrecorded)))
    let differences = try await book.lifecycle(2)?.differences
    let id = try await book.run(approving(book, 2, revision: head, as: .asWritten(seen: rewritten)))
    let approval = try #require(try await book.approvals(2).first)
    #expect(approval.approvalKind == .known(.asWritten))
    #expect(approval.upstreamDigest == differences)
    #expect(try await book.view(2) == LifecycleView(review: .approved, approval: id))
  }

  @Test func shouldApproveAsWrittenADraftThatIsNotStaleAsAStandardApproval() async throws {
    let book = try await ChapterBook.make()
    let head = try await book.draft(1)
    _ = try await book.run(approving(book, 1, revision: head, as: .asWritten(seen: rewritten)))
    #expect(try await book.approvals(1).first?.approvalKind == .known(.standard))
  }

  @Test func shouldRefuseToApproveAsWrittenOverARevealThatNoLongerHolds() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1, learns: [reveal("mara", "heir")])
    let head = try await book.draft(1)
    try await lockHeir(book)
    let cause = try #require(try await book.lifecycle(1)?.stale)
    #expect(cause == .reveal(violations: "heir (needs chapter 5 or later)"))
    await book.expect(.draftStale(chapter: 1, reason: cause.reason), approving(book, 1, revision: head))
    await book.expect(.draftRevealStale(1), approving(book, 1, revision: head, as: .asWritten(seen: cause)))
  }

  @Test func shouldRefuseWhileThePlanRevealsALockedFactEvenOverAnEarlierCause() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(2, learns: [reveal("mara", "heir")])
    try await staleSecond(book)
    try await lockHeir(book)
    let head = try #require(try await book.head(2))
    #expect(try await book.lifecycle(2)?.stale == rewritten)
    await book.expect(.planRevealsHeld(chapter: 2, violations: "heir (needs chapter 5 or later)"), approving(book, 2, revision: head, as: .asWritten(seen: rewritten)))
  }

  @Test func shouldRefuseAMissingFinalOrMovedDraft() async throws {
    let book = try await ChapterBook.make()
    await book.expect(.draftNotFound(1), approving(book, 1, revision: "v:read"))
    let head = try await book.draft(1)
    await book.expect(.draftConflict(chapter: 1, head: head), approving(book, 1, revision: "v:read"))
    try await book.approve(1)
    try await book.finalize(1)
    await book.expect(.draftFinal(1), approving(book, 1, revision: head))
  }

  @Test func shouldRefuseAPlanHeadThisVersionCannotRead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.plan(1)
    let head = try await book.draft(1)
    try await book.run { _ = try $0.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 1), body: .object(["body": .int(1)])) }
    await book.expect(.unreadable(try ChapterPlanRecord.ref(novel: novel, chapter: 1)), approving(book, 1, revision: head))
  }
}
