import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

@Suite("Chat turn search lookups", TestTimeLimit.standard)
struct ChatTurnSearchLookupTests {
  @Test func shouldAnswerATurnAfterTheModelSearchesTheLore() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [
      World.reply(
        ("reply", World.text("Let me search.")),
        ("lookups", #"[{"tool":"search_lore","args":{"query":"Mara","kinds":["character"]}},{"tool":"search_prose","args":{"query":"Mara"}}]"#)),
      World.reply(("reply", World.text("Mara is in the cast."))),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    let outcome = await handle.outcome()
    let replyID = try World.reply(of: outcome)

    let results = try #require(provider.requests[1].messages.last?.text)
    #expect(results.hasPrefix("Lookup results:\n### search_lore\ncharacter:mara — Mara"))
    #expect(results.contains("\n\n### search_prose\n"))
    let messages = try await World.messages(in: book.store)
    let reply = try #require(messages.first { $0.id == replyID })
    #expect(reply.content == "Mara is in the cast.")
    let sources = reply.trace?.objectValue?["sources"]?.arrayValue ?? []
    #expect(sources.map { $0.objectValue?["tool"] } == [.string("search_lore"), .string("search_prose")])
    #expect(provider.requests[0].system.map(\.text).joined().contains("- search_lore (args: kinds, query) — Search the lore knowledge base"))
  }

  @Test func shouldSettleEveryStartedLookupAsAnErrorWhenTheTurnIsCancelledMidRound() async throws {
    let book = try await World.book()
    let retrieval = NovelRetrieval(store: book.store, embedders: FakeEmbedders(embedder: FakeEmbedder()))
    try await retrieval.catchUp(novel: book.novel)
    #expect(try await retrieval.embedPending(novel: book.novel).isComplete)
    let lookups = #"[{"tool":"search_lore","args":{"query":"Mara"}},{"tool":"search_lore","args":{"query":"thief"}}]"#
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Searching.")), ("lookups", lookups))])
    let cancelling = FakeEmbedders(embedder: FakeEmbedder(cancelOnCall: 1))
    let engine = try await World.engine(book.store, provider: provider, embedders: cancelling)
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    #expect(await handle.outcome() == .cancelled)

    let events = await World.events(handle).compactMap { event -> [String]? in
      guard case .lookup(let lookup) = event else { return nil }
      return [lookup.tool, lookup.args["query"]?.stringValue ?? "", "\(lookup.status)"]
    }
    #expect(events == [["search_lore", "Mara", "running"], ["search_lore", "thief", "running"], ["search_lore", "Mara", "error"], ["search_lore", "thief", "error"]])
    #expect(provider.requests.count == 1)
  }
}
