import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private func titled(_ text: String) -> [ScriptedModelProvider.Step] {
  ScriptedModelProvider.reply(String(decoding: CanonicalJSON.encode(.object(["title": .string(text)])), as: UTF8.self))
}

/// A turn begun as `send` begins one, then left: what a crash right after the author's message leaves.
private func begunTurn(_ content: String, engine: ChatTurnEngine, book: ChapterBook) async throws -> ChatTurnBasis {
  let turn = UUID()
  let prepared = try await engine.prepare(
    .new(content: content, passages: [], choices: ChatTurnChoices()), session: World.session, novel: book.novel, turn: turn,
    router: try await CompactionWorld.router(ScriptedModelProvider(), store: book.store))
  let replica = book.store.replica
  try await book.run { transaction in
    if let message = prepared.message { _ = try message.append(in: &transaction) }
    try LocalTurnStore.begin(turn, novel: book.novel, session: World.session, userMessage: prepared.basis.userMessage, replica: replica, at: Date(), in: transaction.database)
    try ChatTurnRecords.save(prepared.basis, in: transaction.database)
  }
  return prepared.basis
}

// The session upkeep the engine runs through Domain/Chat: naming beside the turn (chat.service.ts:331), clearing deleted chats at launch.
@Suite("Chat turn session upkeep", TestTimeLimit.standard)
struct ChatTurnUpkeepTests {
  @Test func shouldNameTheSessionFromItsOpeningMessageAndCarryTheTitlesCallsWhenItFinishesFirst() async throws {
    let book = try await World.book()
    let titles = ScriptedModelProvider(calls: [titled("Mara's dockside trade")])
    let turns = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Noted."))), World.reply(("reply", World.text("Kael.")))])
    let (named, settled) = (Signal(), Signal())
    let engine = try await World.vaultEngine(book.store, provider: TitleSplittingProvider(titles: titles, turns: turns, turnsWait: settled), named: named)
    // the turn asks once the naming has recorded its end, so the naming finishes first
    let gate = Task {
      await named.wait()
      await engine.namingsSettled()
      settled.raise()
    }
    let reply = try World.reply(of: await engine.send(World.message, session: World.session, novel: book.novel).outcome())
    await gate.value

    #expect(titles.requests.count == 1 && turns.requests.count == 1)
    let session = try await book.store.read { try ChatSessionRecord.read(id: World.session, in: $0).entry?.record }
    #expect(session?.autoTitle == "Mara's dockside trade")
    let message = try #require(try await World.messages(in: book.store).last)
    #expect(message.id == reply && message.modelCalls?.count == 2)

    _ = try World.reply(of: await engine.send("And her fence?", session: World.session, novel: book.novel).outcome())
    #expect(titles.requests.count == 1)
  }

  @Test func shouldForgetAChatDeletedOnAnotherDeviceBeforeResumingAtLaunch() async throws {
    let book = try await World.book()
    let basis = try await begunTurn("Plan the heist.", engine: try await World.engine(book.store, provider: ScriptedModelProvider()), book: book)
    try await book.run { try TurnStagingMarks.record(.cards(proposal: nil), reply: basis.reply, session: basis.session, in: $0.database) }
    try await book.run { _ = try ChatSessionRecord.remove(id: World.session, in: &$0) }

    let provider = ScriptedModelProvider()
    let engine = try await World.vaultEngine(book.store, provider: provider)
    #expect(try await engine.resumeInterruptedTurns().isEmpty)
    #expect(provider.requests.isEmpty)
    #expect(try await World.localTurn(basis.turn, in: book.store) == nil)
    #expect(try await World.record(basis.turn, in: book.store) == nil)
    #expect(try await World.stepRows(in: book.store) == 0)
  }

  @Test func shouldLeaveNoInspectorOrTurnRecordsOfADeletedChat() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Noted.")))]))
    let reply = try World.reply(of: await engine.send("One.", session: World.session, novel: book.novel).outcome())
    let basis = try await begunTurn("Two.", engine: engine, book: book)
    #expect(try await book.store.chatCallInspection(reply: reply) != nil)
    #expect(try await World.record(basis.turn, in: book.store) != nil)
    try await book.run { try TurnStagingMarks.record(.cards(proposal: nil), reply: basis.reply, session: basis.session, in: $0.database) }
    #expect(try await World.stepRows(in: book.store) == 1)

    try await book.store.deleteChatSession(World.session, novel: book.novel)
    #expect(try await book.store.chatCallInspection(reply: reply) == nil)
    #expect(try await World.record(basis.turn, in: book.store) == nil)
    #expect(try await World.stepRows(in: book.store) == 0)
    #expect(try await World.localTurn(basis.turn, in: book.store) == nil)
  }

  @Test func shouldLeaveNoInspectorOrTurnRecordsOfAForgottenNovel() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Noted.")))]))
    let reply = try World.reply(of: await engine.send("One.", session: World.session, novel: book.novel).outcome())
    let basis = try await begunTurn("Two.", engine: engine, book: book)
    try await book.run { try TurnStagingMarks.record(.cards(proposal: nil), reply: basis.reply, session: basis.session, in: $0.database) }

    try await book.store.forgetLocalChats(novel: book.novel)
    #expect(try await book.store.chatCallInspection(reply: reply) == nil)
    #expect(try await World.record(basis.turn, in: book.store) == nil)
    #expect(try await World.stepRows(in: book.store) == 0)
  }
}
