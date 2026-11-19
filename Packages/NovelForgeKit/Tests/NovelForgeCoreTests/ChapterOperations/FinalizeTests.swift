import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Finalize and final chapters", TestTimeLimit.standard)
struct FinalizeTests {
  private func finalizing(_ book: ChapterBook, _ chapter: Int?) -> BookWrite<Int> {
    let novel = book.novel
    return { try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &$0) }
  }

  private func amending(_ book: ChapterBook, _ chapter: Int, _ amendment: ChapterAmendment) -> BookWrite<Void> {
    let novel = book.novel
    return { try FinalChapters.amend(novel: novel, chapter: chapter, amendment, in: &$0) }
  }

  private func summarizing(_ book: ChapterBook, _ chapter: Int, _ summary: String) -> BookWrite<Void> {
    let novel = book.novel
    return { try FinalChapters.editSummary(novel: novel, chapter: chapter, summary: summary, in: &$0) }
  }

  @Test func shouldBindTheCanonToTheApprovalInForceAndCopyThePlansContract() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let planned = contract(learns: [Learn("mara", "heir")], claims: ["rise"])
    try await book.run { try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(volume: "one", planned), in: &$0) }
    let head = try await book.save(1, "The tide\r\nturns.", title: "Tide", summary: "It turns.", base: nil).base
    let approval = try await book.approve(1)
    #expect(try await book.run(finalizing(book, 1)) == 1)
    let canon = try #require(try await book.final(1)).canon
    let plan = try await book.store.read { transaction in
      try ChapterPlanRecord.history(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: transaction).history
    }
    #expect(canon.draftRevision == head)
    #expect(canon.planRevision == plan?.head)
    #expect(canon.approval == approval)
    #expect(canon.contract == planned)
    #expect(canon.volume == "one")
    #expect(canon.title == "Tide")
    #expect(canon.body == "The tide\nturns.")
    #expect(canon.summary == "It turns.")
    #expect(canon.generator == .known(.human))
    #expect(plan?.marks[.finalized] == plan?.head)
    let entry = try #require(try await Projection.finals(in: book.store).first)
    #expect(entry.approval == approval)
  }

  @Test func shouldFinalizeTheLowestApprovedChapterWhenNoneIsNamed() async throws {
    let book = try await ChapterBook.make()
    await book.expect(.draftNotFound(nil), finalizing(book, nil))
    try await book.draft(1)
    await book.expect(.draftNotFound(nil), finalizing(book, nil))
    try await book.approve(1)
    #expect(try await book.run(finalizing(book, nil)) == 1)
    #expect(try await book.view(1)?.review == .final)
  }

  @Test func shouldRefuseInTheReferencesOrder() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    await book.expect(.draftNotFound(1), finalizing(book, 1))
    try await book.save(1, "One.", summary: "  ", base: nil)
    await book.expect(.draftNotApproved(1), finalizing(book, 1))
    try await book.approve(1)
    await book.expect(.summaryMissing(1), finalizing(book, 1))
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "One.", isolated: true), base: nil, in: &$0) }
    try await book.approve(1)
    await book.expect(.isolatedWithoutSummary(1), finalizing(book, 1))
    try await book.draft(1)
    try await book.draft(2)
    try await book.approve(2)
    await book.expect(.finalizeOutOfOrder(2), finalizing(book, 2))
    try await book.approve(1)
    try await book.finalize(1)
    await book.expect(.draftFinal(1), finalizing(book, 1))
    try await book.finalize(2)
  }

  @Test func shouldRefuseWhenThePlanTermsChangedAfterApproval() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1)
    try await book.draft(1)
    try await book.approve(1)
    try await book.plan(1, learns: [reveal("mara", "heir")])
    await book.expect(.draftNotApproved(1), finalizing(book, 1))
  }

  @Test func shouldAmendTheTextOfTheCanonThatStandsAndKeepWhatWasNotSent() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 1)
    let before = try #require(try await book.final(1))
    try await book.run(amending(book, 1, ChapterAmendment(content: "Amended\r\nprose.", note: "A note.")))
    let after = try #require(try await book.final(1))
    #expect(after.text == FinalChapterText(title: before.text.title, body: "Amended\nprose.", note: "A note.", summary: "It turns."))
    #expect(after.canon == before.canon)
    #expect(after.canonDigest == before.canonDigest)
    let changes = try await book.store.pendingChanges(limit: .max).count
    try await book.run(amending(book, 1, ChapterAmendment(content: "Amended\nprose.")))
    #expect(try await book.store.pendingChanges(limit: .max).count == changes)
    try await book.run(amending(book, 1, ChapterAmendment(content: "Again.", title: "Retitled")))
    #expect(try await book.final(1)?.text == FinalChapterText(title: "Retitled", body: "Again.", note: "A note.", summary: "It turns."))
  }

  @Test func shouldEditTheSummaryOfAFinalChapterOnly() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 1)
    try await book.run(summarizing(book, 1, "The tide turned."))
    #expect(try await book.final(1)?.text.summary == "The tide turned.")
    #expect(try await book.final(1)?.text.body == "The tide turns.")
    await book.expect(.empty(field: "summary"), summarizing(book, 1, ""))
    try await book.draft(2)
    await book.expect(.chapterNotFinal(2), summarizing(book, 2, "Two."))
    await book.expect(.chapterNotFound(3), summarizing(book, 3, "Three."))
  }

  @Test func shouldRefuseToAmendWhatIsNotFinalOrWithoutProse() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1)
    await book.expect(.chapterNotFinal(1), amending(book, 1, ChapterAmendment(content: "x")))
    await book.expect(.chapterNotFound(2), amending(book, 2, ChapterAmendment(content: "x")))
    await book.expect(.empty(field: "content"), amending(book, 1, ChapterAmendment(content: "")))
    let other = SchemaFixture.otherNovel
    await book.expect(.novelNotFound(other)) { try FinalChapters.amend(novel: other, chapter: 1, ChapterAmendment(content: "x"), in: &$0) }
  }
}
