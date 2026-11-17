import Foundation
import NovelForgeCore
import ShadowAI
import Testing

@testable import NovelForge

@MainActor
@Suite("Chat timeline")
struct ChatTimelineTests {
  @Test("should fold deltas and changes, void both on a reset and keep the reply id")
  func shouldFoldDeltasAndChangesAndVoidThemOnReset() {
    var turn = StreamedTurn(turn: UUID(), startedAt: Date())
    turn.apply(.delta("Let me "))
    turn.apply(.delta("check."))
    turn.apply(.change(TurnChangeEvent(index: 0, op: "entity.upsert", label: "Mara", group: .people)))
    #expect(turn.text == "Let me check.")
    #expect(turn.lastWrite == .change)
    #expect(ChatTurnTimeline.tail(turn, mode: .auto) == ChatTurnTimeline.saving(1, mode: .auto))

    turn.apply(.reset)
    #expect(turn.text.isEmpty && turn.changes.isEmpty && turn.lastWrite == nil)
    #expect(ChatTurnTimeline.tail(turn, mode: .manual) == String(localized: "Thinking", table: "Chat"))

    turn.apply(.change(TurnChangeEvent(index: 0, op: "entity.upsert", label: "Mara", group: .people)))
    turn.apply(.change(TurnChangeEvent(index: 0, op: "entity.upsert", label: "Mara Vance", group: .people)))
    #expect(turn.changes.map(\.label) == ["Mara Vance"])

    let reply = UUID()
    turn.apply(.done(reply: reply))
    turn.finish()
    #expect(turn.reply == reply && turn.isFinished)
  }

  @Test("should name lookups as the reference does")
  func shouldNameLookupsAsTheReferenceDoes() {
    #expect(ChatLookupLabel.label(tool: "get_entity", argumentsJSON: #"{"entityKey":"character:mara_vance"}"#) == "Profile of Mara vance")
    #expect(ChatLookupLabel.label(tool: "get_draft", argumentsJSON: #"{"chapter":3}"#) == "Chapter 3 draft")
    #expect(ChatLookupLabel.label(tool: "get_chapter_summaries", argumentsJSON: #"{"from":2,"to":2}"#) == "Summary of chapter 2")
    #expect(
      ChatLookupLabel.label(tool: "get_notes", argumentsJSON: #"{"query":"a very long question about the harbour and the tides"}"#)
        == "Notes mentioning “a very long question about the harbour a…”")
    #expect(ChatLookupLabel.label(tool: "get_bible_document", argumentsJSON: #"{"slug":"magic-system"}"#) == "Magic system")
    #expect(ChatLookupLabel.label(tool: "search_web", argumentsJSON: "{}") == ChatLookupLabel.generic)
    let lookup = StreamedLookup(id: "x", tool: "get_entity", label: "Profile of Mara", status: .running)
    #expect(ChatLookupLabel.reading(lookup) == "Reading profile of Mara")
  }

  @Test("should format elapsed time, costs and failures as the reference does")
  func shouldFormatElapsedCostsAndFailures() {
    #expect(ChatTurnTimeline.elapsed(9.7) == "9s")
    #expect(ChatTurnTimeline.elapsed(65) == "1m 05s")
    #expect(ChatReplyTag.usd(Cost(nanoUSD: 400_000)).hasPrefix("<"))
    #expect(ChatReplyTag.usd(Cost(nanoUSD: 12_300_000)).contains("0.012"))
    #expect(ChatReplyTag.usd(Cost(nanoUSD: 1_500_000_000)).contains("1.50"))
    #expect(ChatErrors.copy(for: TurnFailure(code: "CHT_013", message: "")).title == String(localized: "This reply was interrupted", table: "Chat"))
    #expect(ChatErrors.copy(for: TurnFailure(code: "routing.credential_missing", message: "")).opensSettings)
    #expect(ChatErrors.copy(for: TurnFailure(code: "new.code", message: "")).title == String(localized: "That turn didn't finish", table: "Chat"))
  }
}
