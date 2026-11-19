import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Draft versions", TestTimeLimit.standard)
struct DraftVersionTests {
  private func versions(_ book: ChapterBook, _ chapter: Int) async throws -> [DraftVersion] {
    let novel = book.novel
    return try await book.store.read { try DraftVersions.list(novel: novel, chapter: chapter, in: $0) }
  }

  private func restore(_ book: ChapterBook, _ chapter: Int, _ revision: String, base: String?) async throws -> String {
    let novel = book.novel
    return try await book.run { try DraftVersions.restore(novel: novel, chapter: chapter, revision: revision, base: base, in: &$0) }
  }

  @Test func shouldListVersionsNewestFirstWithTheCurrentAndTheLatestApprovedOne() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "One.")
    try await book.approve(1)
    let second = try await book.draft(1, "Two.")
    let restored = try await restore(book, 1, first, base: second)
    let listed = try await versions(book, 1)
    #expect(listed.map(\.revision) == [restored, second, first])
    #expect(listed.map(\.isCurrent) == [true, false, false])
    #expect(listed.map(\.isApproved) == [false, false, true])
    #expect(listed.map(\.source) == [.known(.restored), .known(.handEdited), .known(.handEdited)])
    #expect(listed.map(\.restoredFrom) == [first, nil, nil])
  }

  @Test func shouldRefuseToListAMissingOrRemovedDraft() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    await book.expectRead(.draftNotFound(1)) { try DraftVersions.list(novel: novel, chapter: 1, in: $0) }
    try await book.draft(1)
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    await book.expectRead(.draftNotFound(1)) { try DraftVersions.list(novel: novel, chapter: 1, in: $0) }
  }

  @Test func shouldRestoreTheOldTextAsARevisionThatNeedsApprovingAgain() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.save(1, "One.", title: "First", summary: "Once.", base: nil).base
    try await book.run { transaction in
      var content = try #require(try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.content)
      content.title = nil
      content.body = "Untitled."
      content.summary = nil
      content.isolated = true
      _ = try DraftRecord.revise(try DraftRecord.ref(novel: novel, chapter: 1), content, in: &transaction)
    }
    let untitled = try #require(try await book.head(1))
    let second = try await book.save(1, "Two.", title: "Second", summary: "Twice.", base: nil).base
    try await book.approve(1)
    let restored = try await restore(book, 1, untitled, base: second)
    let content = try #require(try await book.draftContent(1))
    #expect(content.body == "Untitled.")
    #expect(content.title == "Second")
    #expect(content.summary == nil)
    #expect(content.isolated)
    #expect(content.restoredFrom == untitled)
    #expect(try await book.view(1) == LifecycleView(review: .needsReview))
    #expect(try await restore(book, 1, restored, base: restored) == restored)
    #expect(try await restore(book, 1, first, base: nil) != restored)
  }

  @Test func shouldRefuseAFinalChapterAMovedBaseAndAnUnknownVersion() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.finalized(through: 1)
    let final = try #require(try await book.head(1))
    await book.expect(.versionFinal(1)) { try DraftVersions.restore(novel: novel, chapter: 1, revision: final, base: final, in: &$0) }
    let head = try await book.draft(2)
    await book.expect(.draftConflict(chapter: 2, head: head)) { try DraftVersions.restore(novel: novel, chapter: 2, revision: head, base: "v:read", in: &$0) }
    await book.expect(.versionNotFound(chapter: 2, revision: "v:ghost")) { try DraftVersions.restore(novel: novel, chapter: 2, revision: "v:ghost", base: head, in: &$0) }
    await book.expect(.draftNotFound(3)) { try DraftVersions.restore(novel: novel, chapter: 3, revision: head, base: nil, in: &$0) }
  }

  @Test func shouldKeepARestoredDraftIsolatedWhenEitherTheHeadOrTheVersionIs() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let isolated = try await book.run {
      try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Walled.", isolated: true), base: nil, in: &$0)
    }
    let open = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Open.", isolated: false), base: isolated, in: &$0) }
    #expect(try await book.draftContent(1)?.isolated == false)
    let walled = try await restore(book, 1, isolated, base: open)
    #expect(try await book.draftContent(1)?.isolated == true)
    _ = try await restore(book, 1, open, base: walled)
    #expect(try await book.draftContent(1)?.body == "Open.")
    #expect(try await book.draftContent(1)?.isolated == true)
  }

  @Test func shouldKeepTheWorkingCopyAsAVersionBeforeRestoring() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    book.clock.advance(by: 700)
    let second = try await book.draft(1, "B")
    book.clock.advance(by: 5)
    try await book.save(1, "BC", base: second)
    _ = try await restore(book, 1, first, base: second)
    let listed = try await versions(book, 1)
    #expect(listed.count == 4)
    #expect(try await book.draftContent(1)?.body == "A")
    #expect(try await book.workingCopy(1) == nil)
  }
}
