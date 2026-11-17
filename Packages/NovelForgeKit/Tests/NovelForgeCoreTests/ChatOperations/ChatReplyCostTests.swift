import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = ChatOperationsWorld

private let usage = TokenUsage(input: 100, output: 20, cacheRead: 5)

private func start(_ id: UUID = UUID()) -> ModelCallStart {
  ModelCallStart(id: id, provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: 1_800_000_000_000)
}

/// A finished call the provider priced.
private func reported(_ nanoUSD: Int64, in store: VaultStore) async throws -> UUID {
  let call = start()
  _ = try await store.write { transaction in
    try Ledger.begin(call, in: &transaction)
    return try Ledger.finish(
      call, events: [.started(requestID: "r", generationID: "g"), .finished(usage: usage, reportedCost: Cost(nanoUSD: nanoUSD), stop: .endTurn)], endedWith: nil,
      catalog: nil, in: &transaction)
  }
  return call.id
}

/// A finished call priced from the catalog.
private func computed(_ nanoUSD: Int64, in store: VaultStore) async throws -> UUID {
  let id = UUID()
  let entry = ModelCallEntry(
    id: id, provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: 1, outcome: .finished, usage: usage, cost: Cost(nanoUSD: nanoUSD),
    costSource: .computed)
  try await store.write { transaction in try Ledger.open(entry, in: &transaction) }
  return id
}

/// A call that abandoned one billed attempt, whose price OpenRouter has not reported yet, then finished priced.
private func retried(_ nanoUSD: Int64, in store: VaultStore) async throws -> UUID {
  let call = start()
  let events: [ModelEvent] = [
    .started(requestID: "r1", generationID: "g1"),
    .retrying(attempt: 1, delay: .seconds(1), cause: .server(status: 500), requestID: "r1", generationID: "g1"),
    .started(requestID: "r2", generationID: "g2"), .finished(usage: usage, reportedCost: Cost(nanoUSD: nanoUSD), stop: .endTurn),
  ]
  _ = try await store.write { transaction in
    try Ledger.begin(call, in: &transaction)
    return try Ledger.finish(call, events: events, endedWith: nil, catalog: nil, in: &transaction)
  }
  return call.id
}

private func costs(_ replies: [ChatReplyCalls], in store: VaultStore) async throws -> [UUID: ChatReplyCost] {
  try await store.load(ChatReplyCosts.self, replies).costs
}

@Suite("Cost per reply", .timeLimit(.minutes(2)))
struct ChatReplyCostTests {
  @Test func shouldSumTheCallsAReplyNamesWithTheEstimatedShareApart() async throws {
    let store = try await World.store()
    let calls = [try await reported(300, in: store), try await computed(200, in: store)]
    _ = try await reported(9_999, in: store)
    let reply = UUID()
    let cost = try #require(try await costs([ChatReplyCalls(message: reply, calls: calls)], in: store)[reply])
    #expect(cost.calls == 2 && cost.cost == Cost(nanoUSD: 500) && cost.estimated == Cost(nanoUSD: 200) && !cost.isPending)
    #expect(cost.usage == TokenUsage(input: 200, output: 40, cacheRead: 10))
  }

  @Test func shouldCountAnAbandonedAttemptAndSayTheCostIsPendingUntilItsPriceArrives() async throws {
    let store = try await World.store()
    let call = try await retried(700, in: store)
    let reply = UUID()
    let cost = try #require(try await costs([ChatReplyCalls(message: reply, calls: [call])], in: store)[reply])
    #expect(cost.calls == 2 && cost.pendingCalls == 1 && cost.missingCalls == 0 && cost.cost == Cost(nanoUSD: 700) && cost.isPending)
    let attempt = try #require(try await store.read { transaction in try Ledger.entries(ofCall: call, in: transaction) }.last?.id)
    _ = try await store.write { transaction in try Ledger.reconcile(id: attempt, cost: Cost(nanoUSD: 50), in: &transaction) }
    let settled = try #require(try await costs([ChatReplyCalls(message: reply, calls: [call])], in: store)[reply])
    #expect(settled.cost == Cost(nanoUSD: 750) && !settled.isPending)
  }

  @Test func shouldSayTheCostIsPendingForACallWhoseEntryHasNotArrived() async throws {
    let store = try await World.store()
    let known = try await reported(300, in: store)
    let reply = UUID()
    let cost = try #require(try await costs([ChatReplyCalls(message: reply, calls: [known, UUID(), known])], in: store)[reply])
    #expect(cost.calls == 1 && cost.missingCalls == 1 && cost.cost == Cost(nanoUSD: 300) && cost.isPending)
  }

  @Test func shouldReadAReplyWithNoCallsAsCostingNothing() async throws {
    let store = try await World.store()
    let reply = UUID()
    let cost = try #require(try await costs([ChatReplyCalls(message: reply, calls: [])], in: store)[reply])
    #expect(cost == ChatReplyCost.summing([], missing: 0) && cost.cost == .zero && !cost.isPending)
  }

  @Test func shouldSaturateRatherThanTrapOnHugeStoredCounts() async throws {
    let huge = TokenUsage(input: .max, output: .max)
    let entry = ModelCallEntry(
      id: UUID(), provider: "api.example.com", model: "m", task: .chat, pace: nil, startedMillis: 1, outcome: .finished, usage: huge, cost: Cost(nanoUSD: .max),
      costSource: .reported)
    let cost = ChatReplyCost.summing([entry, entry], missing: 0)
    #expect(cost.usage.input == .max && cost.cost == Cost(nanoUSD: .max))
  }

  @Test func shouldTakeTheCallsOfThePagesRepliesOnly() async throws {
    let store = try await World.store()
    let session = try await store.createChatSession(novel: World.novel)
    let call = try await reported(300, in: store)
    let author = try ChatMessageRecord(novel: World.novel, session: session.id, role: .user, content: "Tighten it.", modelCalls: [call])
    let reply = try ChatMessageRecord(novel: World.novel, session: session.id, role: .assistant, content: "Done.", modelCalls: [call])
    let silent = try ChatMessageRecord(novel: World.novel, session: session.id, role: .assistant, content: "Older reply.")
    for message in [author, reply, silent] { try await ChatWorld.append(message, in: store) }
    let page = try #require(try await store.load(ChatTranscript.self, ChatTranscriptQuery(session: session.id)).page.value)
    #expect(page.replyCalls == [ChatReplyCalls(message: reply.id, calls: [call])])
    #expect(try await costs(page.replyCalls, in: store)[reply.id]?.cost == Cost(nanoUSD: 300))
  }
}
