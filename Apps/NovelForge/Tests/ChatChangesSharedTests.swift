import Foundation
import NovelForgeCore
import ShadowCore
import Testing

@testable import NovelForge

@MainActor
@Suite("Chat shared follow-ups", .timeLimit(.minutes(3)))
struct ChatChangesSharedTests {
  /// Every catalog value whose plural substitution is followed by another argument: that argument needs its own index, or it reads the first one again.
  @Test func shouldFormatEverySubstitutionWithTheArgumentsThatFollowIt() {
    let rewrite = { (index: Int) in
      ChatOp(index: index, stored: .object(["op": .string("draft.rewrite_passage"), "chapter": .int(4)]), problems: [])
    }
    let reason = "It changed since."

    #expect(ChatOp.title(of: [rewrite(0)]) == "1 change to chapter 4")
    #expect(ChatOp.title(of: [rewrite(0), rewrite(1)]) == "2 changes to chapter 4")
    #expect(String(localized: "Rolled back \(1) changes, then stopped: \(reason)", table: "ChatChanges") == "Rolled back 1 change, then stopped: It changed since.")
    #expect(String(localized: "Rolled back \(3) changes (\(2) with only actions skipped).", table: "ChatChanges") == "Rolled back 3 changes (2 with only actions skipped).")
    #expect(String(localized: "\(1) changes, \(0) undone", table: "ChatChanges") == "1 change, 0 undone")
    #expect(String(localized: "\(1) words, \(2) over the limit", table: "Notebook") == "1 word, 2 over the limit")
    #expect(String(localized: "\(5) of \(100) words", table: "Notebook") == "5 of 100 words")
  }

  @Test func shouldAskTheComposerForFocusToAnswerInTheAuthorsOwnWords() async throws {
    let world = try await ChatWorld.make()
    let session = world.model(of: try await world.session())
    let before = session.composer.focusRequest

    session.composer.requestFocus()

    #expect(session.composer.focusRequest == before + 1)
    #expect(session.draft.isEmpty)
  }

  @Test func shouldSayWhyActionsCouldNotRunAgain() async throws {
    let world = try await ChatWorld.make()
    let tray = ChatTrayModel(context: world.context, engine: world.engine)
    let proposal = UUID()

    await tray.retryActions(proposal)

    #expect(tray.retrying == nil)
    #expect(tray.retryNotices[proposal] == PresentedError(headline: String(localized: "The actions couldn't run again.", table: "ChatChanges"), detail: "RFN_001"))
  }
}
