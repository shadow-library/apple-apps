import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Holding text a save would refuse", .timeLimit(.minutes(2)))
struct ChapterHoldTests {
  private func hold(_ book: ChapterBook, _ body: String, title: String? = nil, base: String) async throws {
    let novel = book.novel
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 1, title: title, body: body, base: base, in: &$0) }
  }

  private func kept(_ book: ChapterBook, _ body: String) async throws -> Bool {
    try await book.history(1)?.revisions.contains { $0.body.body?.body == body } ?? false
  }

  @Test func shouldKeepTheTextAsAVersionWhenAnotherRevisionMovedTheHead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    let other = try await book.run { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Theirs.", source: .generated, in: &$0) }
    try await hold(book, "Mine, refused by a conflict.", title: "T", base: first)
    #expect(try await book.workingCopy(1)?.content.body == "Mine, refused by a conflict.")
    #expect(try await book.workingCopy(1)?.content.title == "T")

    guard case .committed = try await book.save(1, "Later.", base: other) else { throw ChapterBookError.notCommitted }

    #expect(try await kept(book, "Mine, refused by a conflict."))
    #expect(try await book.workingCopy(1) == nil)
  }

  @Test func shouldWriteTheCopyOverTheEditorsOwnBaseWithoutRefusingAConflict() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    try await hold(book, "AB", base: first)
    #expect(try await book.workingCopy(1)?.base == first)
    #expect(try await book.draftContent(1)?.body == "A")
  }

  @Test func shouldHoldTextOverAChapterThatTurnedFinal() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    _ = try await book.approve(1)
    try await book.finalize(1)
    try await hold(book, "Too late.", base: first)
    #expect(try await book.workingCopy(1)?.content.body == "Too late.")
    #expect(try await book.final(1)?.text.body == "A")
  }

  @Test func shouldHoldTextOverARemovedDraftAndOverNone() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    try await hold(book, "After removal.", base: first)
    #expect(try await book.workingCopy(1)?.content.body == "After removal.")
    try await book.save(1, "Again.", base: nil)
    #expect(try await kept(book, "After removal."))
  }

  @Test func shouldNormalizeLineEndingsAndRefuseAnUnknownNovel() async throws {
    let book = try await ChapterBook.make()
    let first = try await book.draft(1, "A")
    try await hold(book, "a\r\nb", base: first)
    #expect(try await book.workingCopy(1)?.content.body == "a\nb")
    let other = SchemaFixture.otherNovel
    await book.expect(.novelNotFound(other)) { try ChapterDrafts.hold(novel: other, chapter: 1, title: nil, body: "x", base: first, in: &$0) }
  }

  @Test func shouldExposeTheNextWritableChapter() {
    #expect(ChapterSequence.nextWritable(draftChapters: [1, 3], finalizedChapters: [2]) == 4)
    #expect(ChapterSequence.nextWritable(draftChapters: [], finalizedChapters: []) == 1)
  }
}
