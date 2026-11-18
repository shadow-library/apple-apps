import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Chat passage source", .timeLimit(.minutes(2)))
struct ChatPassageSourceTests {
  private static let prose = "😀 Mara keeps the harbour keys.\n\nShe never sleeps."

  private func sources(_ book: ChapterBook) async throws -> (source: ChatPassageSource?, engine: ChatPassageSource?) {
    let novel = book.novel
    return try await book.store.read { transaction in
      (
        try ChatPassageSource.load(novel: novel, chapter: 1, in: transaction),
        try ChatTurnDrafts.read([1], novel: novel, in: transaction)[1].map(ChatPassageSource.init)
      )
    }
  }

  private func hold(_ book: ChapterBook, _ body: String, base: String) async throws {
    let novel = book.novel
    try await book.run { try ChapterDrafts.hold(novel: novel, chapter: 1, title: nil, body: body, base: base, in: &$0) }
  }

  private func range(of quote: String, in source: ChatPassageSource) -> NSRange {
    (source.body as NSString).range(of: quote)
  }

  @Test func shouldReadAWorkingCopyThatRestsOnTheHead() async throws {
    let book = try await ChapterBook.make()
    let head = try await book.draft(1, "A")
    try await hold(book, Self.prose, base: head)

    let (source, engine) = try await sources(book)

    #expect(source?.body == Self.prose)
    #expect(source == engine)
  }

  @Test func shouldReadTheHeadUnderACopyOverAMovedHead() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.run { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Theirs.", source: .generated, in: &$0) }
    try await hold(book, "Mine.", base: first)

    let (source, engine) = try await sources(book)

    #expect(source?.body == "Theirs.")
    #expect(source == engine)
  }

  @Test func shouldReadAFinalChapterAsTheTurnDoes() async throws {
    let book = try await ChapterBook.make()
    let head = try await book.draft(1, Self.prose)
    _ = try await book.approve(1)
    try await book.finalize(1)
    try await hold(book, "Too late.", base: head)

    let (source, engine) = try await sources(book)

    #expect(source?.body == Self.prose)
    #expect(source == engine)
  }

  @Test func shouldHaveNoSourceForARemovedDraft() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1, Self.prose)
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }

    let (source, engine) = try await sources(book)

    #expect(source == nil)
    #expect(engine == nil)
  }

  @Test func shouldHaveNoSourceForAnUnreadableHistory() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1, Self.prose)
    try await book.run { _ = try $0.revise(try DraftRecord.ref(novel: novel, chapter: 1), body: .object(["body": .int(1)])) }

    let (source, engine) = try await sources(book)

    #expect(source == nil)
    #expect(engine == nil)
  }

  @Test func shouldSelectInUTF16CodeUnitsWithItsParagraphs() throws {
    let source = ChatPassageSource(chapter: 2, draftId: "draft", revision: 3, body: Self.prose, isolated: false)
    let long = ChatPassageSource(chapter: 2, draftId: "draft", revision: 3, body: String(repeating: "a", count: ChatPassageSource.maxQuoteLength + 1), isolated: false)

    let mara = try source.select(NSRange(location: 3, length: 4)).get()
    let across = try source.select(range(of: "keys.\n\nShe", in: source)).get()

    #expect(mara == ChatPassageSelection(start: 3, end: 7, quote: "Mara", firstParagraph: 1, lastParagraph: 1))
    #expect(across.firstParagraph == 1 && across.lastParagraph == 2)
    #expect(source.select(NSRange(location: 0, length: 0)) == .failure(.empty))
    #expect(source.select(NSRange(location: 31, length: 2)) == .failure(.empty))
    #expect(source.select(NSRange(location: 1, length: 3)) == .failure(.unmapped))
    #expect(source.select(NSRange(location: 40, length: 40)) == .failure(.empty))
    #expect(long.select(NSRange(location: 0, length: ChatPassageSource.maxQuoteLength)).map(\.end) == .success(ChatPassageSource.maxQuoteLength))
    #expect(long.select(NSRange(location: 0, length: ChatPassageSource.maxQuoteLength + 1)) == .failure(.tooLong))
    #expect(source.passage(mara, comment: "  Braver.  ").comment == "Braver.")
    #expect(source.passage(mara, comment: "").passageHash == passageHash("Mara"))
  }

  @Test func shouldBuildPassagesTheTurnResolvesAndTellWhichNoLongerDo() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let head = try await book.draft(1, Self.prose)
    let source = try #require(try await sources(book).source)
    let keys = source.passage(try source.select(range(of: "harbour keys", in: source)).get(), comment: "Braver.")
    let sleeps = source.passage(try source.select(range(of: "She never sleeps.", in: source)).get(), comment: "")

    let drafts = try await book.store.read { try ChatTurnDrafts.read([1], novel: novel, in: $0) }
    let resolved = try ChatTurnDrafts.resolve([keys, sleeps], drafts: drafts)
    #expect(resolved.map(\.start) == [keys.start, sleeps.start])
    #expect(resolved.map(\.firstParagraph) == [1, 2])
    #expect(try await book.store.read { try ChatPassageSource.unresolved([keys, sleeps], novel: novel, in: $0) }.isEmpty)

    try await book.save(1, "😀 Mara lost the keys.\n\nShe never sleeps.", base: head)

    #expect(try await book.store.read { try ChatPassageSource.unresolved([keys, sleeps], novel: novel, in: $0) } == [0])
  }
}
