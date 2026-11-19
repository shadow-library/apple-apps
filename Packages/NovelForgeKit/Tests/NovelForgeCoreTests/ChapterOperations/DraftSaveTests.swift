import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Hand-written draft saves", TestTimeLimit.standard)
struct DraftSaveTests {
  @Test func shouldStartTheNextChapterWithAHandWrittenRevisionThatRecordsItsUpstream() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.save(1, "One\r\nTwo\rThree", title: "Dawn", base: nil)
    let content = try #require(try await book.draftContent(1))
    #expect(first == .committed(revision: try #require(try await book.head(1))))
    #expect(content.body == "One\nTwo\nThree")
    #expect(content.title == "Dawn")
    #expect(content.source == .known(.handEdited))
    #expect(content.generator == .known(.human))
    #expect(content.upstream == DraftUpstream(entries: []))
    try await book.save(2, "Two.", base: nil)
    #expect(try await book.draftContent(2)?.upstream == DraftUpstream(entries: [.draft(chapter: 1, revision: first.base, taught: nil)]))
    #expect(try await book.view(2) == LifecycleView(review: .needsReview))
  }

  @Test func shouldRefuseToStartAChapterOutOfOrderOrAgainstABase() async throws {
    let book = try await ChapterBook.make()
    let (novel, now) = (book.novel, book.clock.now)
    await book.expect(.notNextChapter(chapter: 3, next: 1)) { try ChapterDrafts.save(novel: novel, chapter: 3, DraftEdit(body: "x"), base: nil, at: now, in: &$0) }
    await book.expect(.draftNotFound(1)) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "x"), base: "v:read", at: now, in: &$0) }
    let other = SchemaFixture.otherNovel
    await book.expect(.novelNotFound(other)) { try ChapterDrafts.save(novel: other, chapter: 1, DraftEdit(body: "x"), base: nil, at: now, in: &$0) }
  }

  @Test func shouldRefuseAFinalChapterAndASaveAgainstAnotherRevision() async throws {
    let book = try await ChapterBook.make()
    let (novel, now) = (book.novel, book.clock.now)
    try await book.finalized(through: 1)
    await book.expect(.draftFinal(1)) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "x"), base: nil, at: now, in: &$0) }
    let head = try await book.draft(2)
    await book.expect(.draftConflict(chapter: 2, head: head)) { try ChapterDrafts.save(novel: novel, chapter: 2, DraftEdit(body: "x"), base: "v:read", at: now, in: &$0) }
  }

  @Test func shouldWriteNothingForAnUnchangedHandEdit() async throws {
    let book = try await ChapterBook.make()
    let head = try await book.draft(1, "Same.")
    let before = try await book.store.pendingChanges(limit: .max).count
    #expect(try await book.save(1, "Same.", base: head) == .unchanged(revision: head))
    #expect(try await book.store.pendingChanges(limit: .max).count == before)
  }

  @Test func shouldHoldAutosavesInTheWorkingCopyUntilTheFoldWindowHasPassed() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    book.clock.advance(by: 10)
    #expect(try await book.save(1, "AB", base: first) == .held(base: first))
    book.clock.advance(by: 300)
    #expect(try await book.save(1, "ABC", summary: "New.", base: first) == .held(base: first))
    #expect(try await book.head(1) == first)
    #expect(try await book.revisionCount(1) == 1)
    let copy = try #require(try await book.workingCopy(1))
    #expect(copy.base == first)
    #expect(copy.content.body == "ABC")
    #expect(copy.content.summary == "New.")
    book.clock.advance(by: 290)
    guard case .committed(let second) = try await book.save(1, "ABCD", base: first) else { throw ChapterBookError.notCommitted }
    #expect(try await book.workingCopy(1) == nil)
    #expect(try await book.revisionCount(1) == 2)
    #expect(try await book.draftContent(1)?.body == "ABCD")
    #expect(try await book.draftContent(1)?.summary == "New.")
    book.clock.advance(by: 10)
    #expect(try await book.save(1, "ABCDE", base: second) == .held(base: second))
  }

  @Test func shouldCommitAtOnceOverAGeneratedApprovedOrStaleHeadOrWithoutABase() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let generated = try await book.run { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Generated.", source: .generated, in: &$0) }
    guard case .committed(let edited) = try await book.save(1, "Edited.", base: generated) else { throw ChapterBookError.notCommitted }
    try await book.approve(1)
    guard case .committed = try await book.save(1, "Edited again.", base: edited) else { throw ChapterBookError.notCommitted }
    let second = try await book.draft(2, "Two.")
    try await book.draft(1, "Rewritten.")
    #expect(try await book.view(2)?.stale == "ancestor chapter 1 was hand_edited")
    guard case .committed = try await book.save(2, "Two, again.", base: second) else { throw ChapterBookError.notCommitted }
    #expect(try await book.view(2)?.stale == nil)
    book.clock.advance(by: 5)
    let head = try #require(try await book.head(2))
    guard case .committed = try await book.save(2, "Two, a third time.", base: nil) else { throw ChapterBookError.notCommitted }
    #expect(try await book.head(2) != head)
  }

  @Test func shouldCommitTheWorkingCopyOnLeavingTheEditor() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    #expect(try await book.run { try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: 1, in: &$0) } == nil)
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB", base: first)
    let committed = try await book.run { try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: 1, in: &$0) }
    #expect(committed == (try await book.head(1)))
    #expect(committed != first)
    #expect(try await book.draftContent(1)?.body == "AB")
    #expect(try await book.draftContent(1)?.upstream == DraftUpstream(entries: []))
    #expect(try await book.workingCopy(1) == nil)
  }

  @Test func shouldDropAWorkingCopyThatCameBackToTheHeadWithoutARevision() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB", base: first)
    #expect(try await book.save(1, "A", base: first) == .held(base: first))
    #expect(try await book.run { try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: 1, in: &$0) } == first)
    #expect(try await book.revisionCount(1) == 1)
    #expect(try await book.workingCopy(1) == nil)
  }

  @Test func shouldKeepAWorkingCopyWhoseRevisionWasReplacedUntilItIsDiscarded() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB", base: first)
    let replaced = try await book.run { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Theirs.", source: .generated, in: &$0) }
    await book.expect(.draftConflict(chapter: 1, head: replaced)) { try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: 1, in: &$0) }
    #expect(try await book.workingCopy(1)?.content.body == "AB")
    try await book.run { try ChapterDrafts.discardWorkingCopy(novel: novel, chapter: 1, in: $0) }
    #expect(try await book.workingCopy(1) == nil)
  }

  @Test func shouldImportProseAsANewRevisionAfterKeepingTheWorkingCopyAsAVersion() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB", base: first)
    let imported = try await book.run {
      try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Pasted.\r\n", title: "Pasted", isolated: true), base: first, in: &$0)
    }
    let content = try #require(try await book.draftContent(1))
    #expect(try await book.head(1) == imported)
    #expect(try await book.revisionCount(1) == 3)
    #expect(content.body == "Pasted.\n")
    #expect(content.title == "Pasted")
    #expect(content.summary == "It turns.")
    #expect(content.source == .known(.imported))
    #expect(content.isolated)
    #expect(try await book.workingCopy(1) == nil)
    await book.expect(.draftConflict(chapter: 1, head: imported)) {
      try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "x"), base: first, in: &$0)
    }
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 2, DraftImport(prose: "Two."), base: nil, in: &$0) }
    #expect(try await book.draftContent(2)?.source == .known(.imported))
  }

  @Test func shouldStartAnEmptyDraftAtTheNextWritableChapter() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.finalized(through: 1)
    try await book.draft(2)
    #expect(try await book.run { try ChapterDrafts.startNext(novel: novel, in: &$0) } == 3)
    #expect(try await book.draftContent(3)?.body == "")
    #expect(try await book.draftContent(3)?.generator == .known(.human))
  }

  @Test func shouldRestartARemovedDraftAsTheNextChapter() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1, "First.")
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    try await book.save(1, "Again.", base: nil)
    #expect(try await book.draftContent(1)?.body == "Again.")
    #expect(try await book.view(1) == LifecycleView(review: .needsReview))
  }

  @Test func shouldCommitTheWorkingCopyBeforeApprovingIt() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB", base: first)
    let approval = try await book.store.approveChapter(novel: book.novel, chapter: 1, revision: first)
    let head = try await book.head(1)
    #expect(head != first)
    #expect(try await book.draftContent(1)?.body == "AB")
    #expect(try await book.lifecycle(1)?.approval == approval)
    #expect(try await book.approvals(1).map(\.draftRevision) == [head])
  }
}
