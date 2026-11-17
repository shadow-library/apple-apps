import Testing

@testable import NovelForgeCore

struct TurnNotesParityTests {
  private static let fixture = Result { try ChatFixture.load("notes.json") }

  @Test func shouldShareEveryTurnNoteWithTheReference() throws {
    let notes: [(String, String)] = [
      ("HELD_FOR_REVIEW_NOTE", heldForReviewNote), ("WRITER_READ_HELD_NOTE", writerReadHeldNote), ("APPLY_FAILED_NOTE", applyFailedNote), ("UNLINKED_NOTE", unlinkedNote),
      ("CARDS_UNSAVED_NOTE", cardsUnsavedNote), ("IDEAS_DROPPED_NOTE", ideasDroppedNote), ("ORGANISE_STARTED_NOTE", organiseStartedNote), ("ORGANISE_BUSY_NOTE", organiseBusyNote),
      ("ORGANISE_REFUSED_NOTE", organiseRefusedNote),
    ]
    let expected = try #require(try Self.fixture.get()["notes"]?.objectValue)
    #expect(expected.keys.count == notes.count)
    for (name, value) in notes { #expect(value.jsEquals(try #require(expected[name]).text), "\(name)") }
  }

  @Test func shouldAskForTheNegationFixAsTheReferenceDoes() throws {
    for (position, item) in try #require(try Self.fixture.get()["negationFix"]).items.enumerated() {
      let warnings = try #require(item["warnings"]).items.map(\.text)
      #expect(negationFixRequest(warnings).jsEquals(try #require(item["expected"]).text), "negation fix \(position)")
    }
  }
}
