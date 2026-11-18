import Foundation
import ShadowAI
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private let stalled: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it. "#), .delay(.seconds(120))]
private let unrestricted = ChatTurnChoices(contentMode: .unrestricted)

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

  /// The naming beside `turn` still owed, as when its title call was in flight when the turn stopped.
  private func oweNaming(_ turn: UUID, _ book: Novel, after first: ChatTurnEngine) async throws {
    let basis = try #require(try await World.record(turn, in: book.store)?.basis)
    #expect(basis.namesSession && basis.contentMode == .unrestricted)
    await first.namingsSettled()
    #expect(try await owedNamings(book) == 0)
    let replica = book.store.replica
    try await book.store.write { transaction in try LocalSessionNamings.owe(ChatSessionNaming(basis), replica: replica, in: transaction.database) }
  }

  private func owedNamings(_ book: Novel) async throws -> Int {
    let replica = book.store.replica
    return try await book.store.read { try LocalSessionNamings.owed(replica: replica, in: $0.database).count }
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

  // From the F29 review: a turn written unrestricted in a build that allowed it, resumed in one that does not, neither asks the model nor names its chat
  @Test func shouldRefuseToResumeAnUnrestrictedTurnAndNameNothing() async throws {
    let book = try await unrestrictedNovel()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Describe the doorway.", session: book.session, novel: book.novel, choices: unrestricted)
    for await event in handle.events {
      if case .delta = event { break }
    }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)
    try await oweNaming(handle.turn, book, after: first)

    let provider = ScriptedModelProvider()
    let upkeep = RecordedUpkeep()
    let engine = try await World.engine(book.store, provider: provider, upkeep: upkeep, unrestrictedAvailable: false)
    let resumed = try await engine.resume(turn: handle.turn)

    #expect(await resumed.outcome() == .failed(ChatTurnFailures.failure(ChatTurnError.unrestrictedUnavailable)))
    #expect(ChatTurnFailures.failure(ChatTurnError.unrestrictedUnavailable).code == "AI_024")
    await engine.namingsSettled()
    #expect(try await owedNamings(book) == 0)
    #expect(provider.requests.isEmpty && upkeep.named.isEmpty)
  }

  // A retry of a turn whose unrestricted answer had settled finishes from that answer, which asks nothing, and names nothing while the flag is off
  @Test func shouldFinishASettledUnrestrictedTurnOnRetryWithoutAskingOrNaming() async throws {
    let book = try await unrestrictedNovel()
    let script = ScriptedModelProvider(calls: [World.reply(("reply", World.text("It opens onto the quay.")))])
    let first = try await World.engine(book.store, provider: script, faults: World.faults(.failure, at: .appending))
    let handle = try await first.send("Describe the doorway.", session: book.session, novel: book.novel, choices: unrestricted)
    guard case .failed = await handle.outcome() else {
      Issue.record("the reply's write did not fail")
      return
    }
    #expect(try await World.record(handle.turn, in: book.store)?.settled != nil)
    try await oweNaming(handle.turn, book, after: first)

    let provider = ScriptedModelProvider()
    let upkeep = RecordedUpkeep()
    let engine = try await World.engine(book.store, provider: provider, upkeep: upkeep, unrestrictedAvailable: false)
    #expect(try World.reply(of: await engine.retry(turn: handle.turn).outcome()) == handle.turn)
    await engine.namingsSettled()
    #expect(try await owedNamings(book) == 0)
    #expect(provider.requests.isEmpty && upkeep.named.isEmpty)
    #expect(try await World.messages(book.session, in: book.store).map(\.contentMode) == [.known(.unrestricted), .known(.unrestricted)])
  }

  @Test func shouldRefuseToRetryAnUnsettledUnrestrictedTurn() async throws {
    let book = try await unrestrictedNovel()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [[.failure(.authentication)]]))
    let handle = try await first.send("Describe the doorway.", session: book.session, novel: book.novel, choices: unrestricted)
    guard case .failed = await handle.outcome() else {
      Issue.record("the turn did not fail")
      return
    }

    let provider = ScriptedModelProvider()
    let engine = try await World.engine(book.store, provider: provider, unrestrictedAvailable: false)
    await #expect {
      _ = try await engine.retry(turn: handle.turn)
    } throws: { error in
      (error as? ChatTurnError)?.code == "AI_024"
    }
    #expect(provider.requests.isEmpty)
  }
}
