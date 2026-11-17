import Foundation
import Testing

@testable import NovelForgeCore

@Suite("Library limits")
struct LibraryLimitsTests {
  @Test
  func shouldCountWordsTheWayTheNotesLimitDoes() {
    #expect(LibraryCounting.words(in: "") == 0)
    #expect(LibraryCounting.words(in: "  \n ") == 0)
    #expect(LibraryCounting.words(in: " one two\u{00A0}three\nfour ") == 4)
    #expect(LibraryCounting.words(in: Array(repeating: "word", count: LibraryLimits.notesWords + 1).joined(separator: " ")) == LibraryLimits.notesWords + 1)
  }

  @Test
  func shouldCountCharactersInUnicodeScalarsOnTheTrimmedText() {
    #expect(LibraryCounting.characters(in: "  ab  ") == 2)
    #expect(LibraryCounting.characters(in: "e\u{0301}") == 2)
    #expect(LibraryCounting.characters(in: "\u{1F600}") == 1)
  }

  @Test
  func shouldRefuseATitleOneScalarOverTheLimit() async throws {
    let world = try LibraryWorld.make()
    let title = String(repeating: "a", count: LibraryLimits.titleCharactersOnCreate + 1)
    await world.expect(.tooLong(field: "title", limit: LibraryLimits.titleCharactersOnCreate)) { _ = try Library.create(NewNovel(title: title), in: &$0) }
  }
}
