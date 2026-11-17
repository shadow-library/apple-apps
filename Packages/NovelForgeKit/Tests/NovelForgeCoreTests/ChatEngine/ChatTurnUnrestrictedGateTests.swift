import Foundation
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

/// Orchestrator decision 5: while the build cannot write unrestricted text, no turn runs unrestricted, whichever way it starts.
@Suite("Chat turn unrestricted gate", .timeLimit(.minutes(3)))
struct ChatTurnUnrestrictedGateTests {
  private struct Novel {
    let store: VaultStore
    let novel: UUID
    let session: UUID
  }

  private func unrestrictedNovel() async throws -> Novel {
    let store = try NovelForgeStore.openInMemory()
    let novel = try await store.writeDomain { transaction throws(DomainError) in
      try Library.create(NewNovel(title: "Ember", contentMode: .unrestricted), in: &transaction)
    }
    let session = try await store.createChatSession(novel: novel).id
    return Novel(store: store, novel: novel, session: session)
  }

  private func transcript(_ book: Novel, unrestricted ordinal: Int? = nil) async throws {
    let messages = try (1...13).map { index in
      try ChatMessageRecord(
        novel: book.novel, session: book.session, role: index.isMultiple(of: 2) ? .assistant : .user, content: "Message \(index).",
        contentMode: index == ordinal ? .unrestricted : .standard)
    }
    try await book.store.write { transaction in for message in messages { _ = try message.append(in: &transaction) } }
  }

  // From the F29 review: the fold an unrestricted novel raised went out unrestricted while the flag was off.
  @Test func shouldFoldStandardForANovelThatIsOnlyUnrestrictedByItsMode() async throws {
    let book = try await unrestrictedNovel()
    try await transcript(book)
    let provider = ScriptedModelProvider(calls: [CompactionWorld.reply("They planned the heist."), World.reply(("reply", World.text("Noted.")))])
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)

    _ = try World.reply(of: try await engine.send("What next?", session: book.session, novel: book.novel).outcome())

    #expect(provider.requests.count == 2)
    #expect(!provider.requests.contains { $0.model == CompactionWorld.unrestrictedModel })
  }

  @Test func shouldRefuseATurnWhoseFoldWouldSendUnrestrictedText() async throws {
    let book = try await unrestrictedNovel()
    try await transcript(book, unrestricted: 2)
    let provider = ScriptedModelProvider()
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)

    await #expect {
      _ = try await engine.send("What next?", session: book.session, novel: book.novel)
    } throws: { error in
      (error as? ChatTurnError)?.code == "AI_024"
    }
    #expect(provider.requests.isEmpty)
    #expect(try await World.messages(book.session, in: book.store).count == 13)
  }

  @Test func shouldRefuseToAnswerAMessageWithNoRecordedModeOnAnUnrestrictedNovel() async throws {
    let book = try await unrestrictedNovel()
    let message = try ChatMessageRecord(novel: book.novel, session: book.session, role: .user, content: "Describe the doorway.")
    try await book.store.write { transaction in _ = try message.append(in: &transaction) }
    let provider = ScriptedModelProvider()
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)

    await #expect {
      _ = try await engine.answer(message: message.id, session: book.session, novel: book.novel)
    } throws: { error in
      (error as? ChatTurnError)?.code == "AI_024"
    }
    #expect(provider.requests.isEmpty)
    #expect(try await book.store.pendingLocalTurns().isEmpty)
  }

  @Test func shouldRefuseANewMessageThatAsksForUnrestrictedWriting() async throws {
    let book = try await unrestrictedNovel()
    let provider = ScriptedModelProvider()
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)

    await #expect {
      _ = try await engine.send("Describe it.", session: book.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .unrestricted))
    } throws: { error in
      (error as? ChatTurnError)?.code == "AI_024"
    }
    #expect(try await World.messages(book.session, in: book.store).isEmpty)
  }

  @Test func shouldWriteANewMessageThatFollowsAnUnrestrictedNovelStandard() async throws {
    let book = try await unrestrictedNovel()
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Plainly.")))])
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)

    let outcome = try await engine.send("Describe it.", session: book.session, novel: book.novel).outcome()

    _ = try World.reply(of: outcome)
    let messages = try await World.messages(book.session, in: book.store)
    #expect(messages.map(\.contentMode) == [.known(.standard), .known(.standard)])
    #expect(provider.requests.first?.model != CompactionWorld.unrestrictedModel)
  }
}
