import SwiftUI
import Testing

@testable import ShadowDesignSystem

private func command(_ id: String, _ title: String, keywords: [String] = []) -> ShadowCommand {
  ShadowCommand(id: id, title: title, systemImage: "book", keywords: keywords) {}
}

@Suite("Command matcher")
struct ShadowCommandMatcherTests {
  @Test("should match everything with no highlights for an empty or blank query", arguments: ["", "   "])
  func emptyQuery(query: String) {
    #expect(ShadowCommandMatcher.match(query, in: "New chapter") == ShadowCommandMatch(score: 0, matchedOffsets: []))
  }

  @Test("should highlight a prefix match")
  func prefix() throws {
    let match = try #require(ShadowCommandMatcher.match("new", in: "New chapter"))
    #expect(match.matchedOffsets == [0, 1, 2])
  }

  @Test("should highlight a word match in the middle of a title")
  func wordPrefix() throws {
    let match = try #require(ShadowCommandMatcher.match("glass", in: "Chapter 42 · The Glass Stair"))
    #expect(match.matchedOffsets == Array(17..<22))
  }

  @Test("should ignore case and diacritics")
  func folding() throws {
    #expect(try #require(ShadowCommandMatcher.match("ECOLE", in: "École des lanternes")).matchedOffsets == [0, 1, 2, 3, 4])
    #expect(ShadowCommandMatcher.match("cafe", in: "Café") != nil)
  }

  @Test("should match full-width input against ASCII titles and the reverse")
  func widthInsensitive() throws {
    #expect(try #require(ShadowCommandMatcher.match("ｇｌａｓｓ", in: "Chapter 42 · The Glass Stair")).matchedOffsets == Array(17..<22))
    #expect(ShadowCommandMatcher.match("glass", in: "ＧＬＡＳＳ") != nil)
  }

  @Test("should treat decomposed and precomposed accents alike")
  func decomposed() throws {
    #expect(try #require(ShadowCommandMatcher.match("café", in: "Cafe\u{301} des lanternes")).matchedOffsets == [0, 1, 2, 3])
    #expect(ShadowCommandMatcher.match("cafe\u{301}", in: "Café") != nil)
  }

  @Test("should match characters that fold to several letters and highlight the original character once")
  func expandingFolds() throws {
    #expect(try #require(ShadowCommandMatcher.match("strasse", in: "Straße der Archivare")).matchedOffsets == [0, 1, 2, 3, 4, 5])
    #expect(ShadowCommandMatcher.match("straße", in: "Strasse") != nil)
    #expect(try #require(ShadowCommandMatcher.match("fin", in: "ﬁnale")).matchedOffsets == [0, 1])
  }

  @Test("should match a subsequence fuzzily and highlight each character")
  func fuzzy() throws {
    let match = try #require(ShadowCommandMatcher.match("fic", in: "Finalize into canon"))
    #expect(match.matchedOffsets == [0, 9, 14])
  }

  @Test("should not match when characters are missing or out of order")
  func noMatch() {
    #expect(ShadowCommandMatcher.match("xyz", in: "New chapter") == nil)
    #expect(ShadowCommandMatcher.match("retpahc", in: "Chapter") == nil)
    #expect(ShadowCommandMatcher.match("chapters and more", in: "Chapter") == nil)
  }

  @Test("should rank prefix above word start above substring above fuzzy")
  func tiers() throws {
    let prefix = try #require(ShadowCommandMatcher.match("can", in: "Canon rules"))
    let word = try #require(ShadowCommandMatcher.match("can", in: "Finalize into canon"))
    let substring = try #require(ShadowCommandMatcher.match("can", in: "Toucan"))
    let fuzzy = try #require(ShadowCommandMatcher.match("can", in: "Chapter and notes"))
    #expect(prefix.score > word.score)
    #expect(word.score > substring.score)
    #expect(substring.score > fuzzy.score)
  }

  @Test("should prefer shorter titles within the same tier")
  func shorterFirst() throws {
    let short = try #require(ShadowCommandMatcher.match("new", in: "New chapter"))
    let long = try #require(ShadowCommandMatcher.match("new", in: "New chapter from template"))
    #expect(short.score > long.score)
  }

  @Test("should prefer word starts when matching fuzzily")
  func fuzzyWordStarts() throws {
    let match = try #require(ShadowCommandMatcher.match("nc", in: "Rename chapter"))
    #expect(match.matchedOffsets == [2, 7])
  }

  @Test("should fall back to the first occurrence when jumping to a word start would lose the rest of the query")
  func fuzzyBacktracks() throws {
    #expect(try #require(ShadowCommandMatcher.match("mak", in: "Mark as Read")).matchedOffsets == [0, 1, 3])
    #expect(try #require(ShadowCommandMatcher.match("mrk", in: "Mark as Read")).matchedOffsets == [0, 2, 3])
    #expect(try #require(ShadowCommandMatcher.match("axz", in: "Bax-Ayz")).matchedOffsets == [1, 2, 6])
  }

  @Test("should ignore extra spaces in the query")
  func extraSpaces() {
    #expect(ShadowCommandMatcher.match("new  doc", in: "New doc") != nil)
    #expect(ShadowCommandMatcher.match("  new ", in: "New doc")?.matchedOffsets == [0, 1, 2])
  }

  @Test("should treat camel case boundaries as word starts")
  func camelCase() {
    #expect(ShadowCommandMatcher.isWordStart(4, in: Array("readingMode")) == false)
    #expect(ShadowCommandMatcher.isWordStart(7, in: Array("readingMode")))
    #expect(ShadowCommandMatcher.isWordStart(3, in: Array("the glass")) == false)
    #expect(ShadowCommandMatcher.isWordStart(4, in: Array("the glass")))
  }

  @Test("should fall back to keywords below every title match and without highlights")
  func keywords() throws {
    let preferences = command("prefs", "Settings", keywords: ["Preferences"])
    let match = try #require(ShadowCommandMatcher.match("pref", in: preferences))
    #expect(match.matchedOffsets.isEmpty)
    let fuzzyTitle = try #require(ShadowCommandMatcher.match("sgs", in: "Settings"))
    #expect(match.score < fuzzyTitle.score)
  }
}

@Suite("Command keyword ranking")
struct ShadowCommandKeywordTests {
  @Test("should keep keyword matches below every title match and ordered by their own tier")
  func tiers() throws {
    let prefix = try #require(ShadowCommandMatcher.match("pref", in: command("a", "Settings", keywords: ["Preferences"])))
    let fuzzy = try #require(ShadowCommandMatcher.match("pfs", in: command("b", "Settings", keywords: ["Preferences"])))
    let fuzzyTitle = try #require(ShadowCommandMatcher.match("sgs", in: "Settings"))
    #expect(prefix.score > fuzzy.score)
    #expect(prefix.score < fuzzyTitle.score)
  }
}

@Suite("Command filter")
struct ShadowCommandFilterTests {
  private let sections = [
    ShadowCommandSection(
      id: "chapters", title: "Chapters",
      commands: [command("c41", "Chapter 41 · Ink and Salt"), command("c42", "Chapter 42 · The Glass Stair"), command("c43", "Chapter 43 · Forty-first step")]),
    ShadowCommandSection(
      id: "commands", title: "Commands",
      commands: [command("new", "New chapter"), command("canon", "Finalize into canon"), command("glassify", "Toggle glass preview")]),
  ]

  @Test("should keep every command in order for an empty query")
  func emptyQuery() {
    let results = ShadowCommandFilter.sections(sections, matching: "")
    #expect(results.map(\.id) == ["chapters", "commands"])
    #expect(results.flatMap(\.results).map(\.id) == ["c41", "c42", "c43", "new", "canon", "glassify"])
  }

  @Test("should keep section order, drop empty sections and rank inside each section")
  func filtered() {
    let results = ShadowCommandFilter.sections(sections, matching: "glass")
    #expect(results.map(\.id) == ["chapters", "commands"])
    #expect(results[0].results.map(\.id) == ["c42"])
    #expect(results[1].results.map(\.id) == ["glassify"])
    #expect(ShadowCommandFilter.sections(sections, matching: "canon").map(\.id) == ["commands"])
  }

  @Test("should rank stronger matches first and keep ties in source order")
  func ranking() {
    let results = ShadowCommandFilter.results(in: [command("a", "Ink and Salt"), command("b", "Salt Kings"), command("c", "Salt road")], matching: "salt")
    #expect(results.map(\.id) == ["c", "b", "a"])
    let ties = ShadowCommandFilter.results(in: [command("a", "Chapter one"), command("b", "Chapter two")], matching: "")
    #expect(ties.map(\.id) == ["a", "b"])
  }

  @Test("should rank the same through the folded index as matching each command directly", arguments: ["", "glass", "chap", "fic", "ｇｌａｓｓ", "zzz"])
  func indexEquivalence(query: String) {
    let indexed = ShadowCommandIndex(sections).sections(matching: query).flatMap(\.results).map(\.match)
    var direct: [ShadowCommandMatch] = []
    for section in sections {
      let matches: [ShadowCommandMatch] = section.commands.compactMap { ShadowCommandMatcher.match(query, in: $0) }
      direct += matches.enumerated().sorted(by: Self.isRankedBefore).map(\.element)
    }
    #expect(indexed == direct)
  }

  private static func isRankedBefore(_ lhs: (offset: Int, element: ShadowCommandMatch), _ rhs: (offset: Int, element: ShadowCommandMatch)) -> Bool {
    lhs.element.score == rhs.element.score ? lhs.offset < rhs.offset : lhs.element.score > rhs.element.score
  }

  @Test("should return nothing when no command matches")
  func noMatches() {
    #expect(ShadowCommandFilter.sections(sections, matching: "zzz").isEmpty)
  }
}

@Suite("Command cursor")
struct ShadowCommandCursorTests {
  @Test("should select the first result")
  func initial() {
    #expect(ShadowCommandCursor(ids: ["a", "b"]).selection == "a")
    #expect(ShadowCommandCursor(ids: []).selection == nil)
  }

  @Test("should move down and up and wrap around the ends")
  func moves() {
    var cursor = ShadowCommandCursor(ids: ["a", "b", "c"])
    cursor.moveDown()
    #expect(cursor.selection == "b")
    cursor.moveDown()
    cursor.moveDown()
    #expect(cursor.selection == "a")
    cursor.moveUp()
    #expect(cursor.selection == "c")
    #expect(cursor.selectedIndex == 2)
  }

  @Test("should do nothing without results")
  func emptyMoves() {
    var cursor = ShadowCommandCursor(ids: [])
    cursor.moveDown()
    cursor.moveUp()
    #expect(cursor.selection == nil)
  }

  @Test("should select a known id on hover and ignore an unknown one")
  func select() {
    var cursor = ShadowCommandCursor(ids: ["a", "b"])
    cursor.select("b")
    #expect(cursor.selection == "b")
    cursor.select("z")
    #expect(cursor.selection == "b")
  }

  @Test("should keep the selection when it survives new results and fall back to the first otherwise")
  func reconcile() {
    var cursor = ShadowCommandCursor(ids: ["a", "b", "c"])
    cursor.select("b")
    cursor.reconcile(with: ["c", "b"])
    #expect(cursor.selection == "b")
    cursor.reconcile(with: ["x", "y"])
    #expect(cursor.selection == "x")
    cursor.reconcile(with: [])
    #expect(cursor.selection == nil)
  }

  @Test("should flatten result sections in display order")
  func fromSections() {
    let sections = ShadowCommandFilter.sections(
      [
        ShadowCommandSection(id: "recent", title: "Recent", commands: [command("r", "Chapter 42")]),
        ShadowCommandSection(id: "actions", title: "Actions", commands: [command("n", "New chapter")]),
      ], matching: "chap")
    var cursor = ShadowCommandCursor(sections: sections)
    #expect(cursor.ids == ["r", "n"])
    cursor.moveDown()
    #expect(cursor.selection == "n")
  }
}

@Suite("Shortcut glyphs")
struct ShadowShortcutGlyphsTests {
  @Test("should order modifiers the way macOS menus do")
  func modifiers() {
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut("f", modifiers: [.command, .shift])) == "⇧⌘F")
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut("k", modifiers: [.command, .option, .control])) == "⌃⌥⌘K")
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut("q", modifiers: [.shift, .command])) == "⇧⌘Q")
  }

  @Test("should draw special keys as glyphs")
  func specialKeys() {
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut(.delete, modifiers: .command)) == "⌘⌫")
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut(.return, modifiers: [])) == "↩")
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut(",", modifiers: .command)) == "⌘,")
    #expect(ShadowShortcutGlyphs.string(for: KeyboardShortcut(.upArrow, modifiers: .option)) == "⌥↑")
  }
}

@Suite("Command highlight")
struct ShadowCommandHighlightTests {
  @Test("should embolden only the matched characters")
  func emboldens() {
    let attributed = ShadowCommandHighlight.attributed("New chapter", offsets: [0, 1, 2], highlight: nil)
    let emphasized = attributed.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(attributed[$0.range].characters) }
    #expect(emphasized == ["New"])
  }

  @Test("should leave the title plain without offsets")
  func plain() {
    let attributed = ShadowCommandHighlight.attributed("New chapter", offsets: [], highlight: nil)
    #expect(attributed.runs.count == 1)
  }
}
