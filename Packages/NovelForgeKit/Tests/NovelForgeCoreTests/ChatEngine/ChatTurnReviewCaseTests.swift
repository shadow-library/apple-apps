import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private func lookupReply(_ n: Int) -> [ScriptedModelProvider.Step] {
  World.reply(("reply", World.text("Checking \(n).")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#))
}

// From the F22b review: the lookup cap, the voided output, a cancel after the answer settled or before the first call, and no unrestricted text in a
// later standard turn
@Suite("Chat turn review cases", .timeLimit(.minutes(3)))
struct ChatTurnReviewCaseTests {
  @Test func shouldCapLookupsAtThreeRoundsAndDropLateLookups() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [
      lookupReply(1), lookupReply(2), lookupReply(3),
      World.reply(("reply", World.text("Final.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#)),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    let reply = try World.reply(of: await engine.send("Who?", session: World.session, novel: book.novel).outcome())
    #expect(provider.requests.count == 4)
    #expect(provider.requests[3].messages.last?.text.contains("Lookup budget exhausted — answer with what you have; do not request more lookups.") == true)
    #expect(provider.requests[2].messages.last?.text.contains("Lookup budget exhausted") == false)
    let record = try #require(try await World.messages(in: book.store).last)
    #expect(record.id == reply && record.content == "Final." && record.appliedProposal == nil && record.cardProposal == nil)
  }

  @Test func shouldVoidWhatWasShownWhenTheOutputScreenRefuses() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("She waited. The schoolgirl looked sexy in the doorway.")))])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Describe the doorway.", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .unrestricted))
    _ = await handle.outcome()
    let events = await World.events(handle)
    let lastDelta = events.lastIndex { if case .delta = $0 { true } else { false } }
    let lastReset = events.lastIndex(of: .reset)
    #expect(lastDelta.map { (lastReset ?? -1) > $0 } ?? true)
  }

  @Test func shouldFinishASettledTurnCancelledAtOnce() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let turn = UUID()
    let prepared = try await engine.prepare(
      .new(content: World.message, passages: [], choices: ChatTurnChoices()), session: World.session, novel: book.novel, turn: turn,
      router: try await CompactionWorld.router(ScriptedModelProvider(), store: book.store))
    let replica = book.store.replica
    try await book.run { transaction in
      if let message = prepared.message { _ = try message.append(in: &transaction) }
      try LocalTurnStore.begin(turn, novel: book.novel, session: World.session, userMessage: prepared.basis.userMessage, replica: replica, at: Date(), in: transaction.database)
      try ChatTurnRecords.save(prepared.basis, in: transaction.database)
    }
    let objects = try #require(try OrderedJSON(parsing: "[\(World.maraThief)]").arrayValue).compactMap(\.objectValue)
    let answer = ChatTurnSettled(reply: "Done.", changeSet: objects, question: nil, warnings: [], trace: .object([:]), calls: [], exchangeMessages: [])
    try await book.run { try ChatTurnRecords.settle(turn, answer, in: $0.database) }
    let fresh = try await World.engine(book.store, provider: ScriptedModelProvider())
    let handle = try await fresh.resume(turn: turn)
    fresh.cancel(turn: turn)
    let outcome = await handle.outcome()
    #expect(outcome == .answered(reply: turn))
    #expect(try await book.entity("mara")?.status == "thief")
    #expect(try await book.store.pendingLocalTurns().isEmpty)
  }

  @Test func shouldEndATurnCancelledBeforeItsFirstCall() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Hi.")))]))
    let handle = try await engine.send("One.", session: World.session, novel: book.novel)
    engine.cancel(turn: handle.turn)
    let outcome = await handle.outcome()
    let local = try await World.localTurn(handle.turn, in: book.store)
    #expect(outcome == .cancelled ? local?.state == .cancelled : local == nil)
    #expect(try await book.store.pendingLocalTurns().isEmpty)
    _ = try World.reply(of: await engine.send("Two.", session: World.session, novel: book.novel).outcome())
  }

  @Test func shouldNeverSendUnrestrictedTextToALaterStandardTurn() async throws {
    let book = try await World.book()
    let secret = "Zorblax whispered the forbidden vow."
    let provider = ScriptedModelProvider(calls: [
      World.reply(("reply", World.text(secret))), World.reply(("reply", World.text("Standard one."))), World.reply(("reply", World.text("Standard two."))),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    _ = try World.reply(
      of: await engine.send("Tell me about the vow.", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .unrestricted)).outcome())
    _ = try World.reply(of: await engine.send("Now plainly.", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .standard)).outcome())
    _ = try World.reply(of: await engine.send("Again.", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .standard)).outcome())
    #expect(provider.requests.count == 3)
    for request in provider.requests.dropFirst() {
      let all = (request.system.map(\.text) + request.messages.map(\.text)).joined()
      #expect(!all.contains("Zorblax"))
    }
    let exchanges = try await book.store.read { try ChatContextExchangeLog.load(session: World.session, in: $0.database) }
    #expect(exchanges.isEmpty)
  }
}
