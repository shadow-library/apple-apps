import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = CompactionWorld

private func message(
  _ ordinal: Int, role: ChatRole = .user, content: String? = nil, mode: ContentMode? = .standard, tokens: Int? = nil, question: JSONValue? = nil
) throws -> ChatMessageRecord {
  try ChatMessageRecord(
    id: World.id(ordinal), novel: ChatWorld.novel, session: ChatWorld.session, role: role, content: content ?? "Message \(ordinal).", contentMode: mode,
    tokens: tokens, question: question)
}

private func exchange(through: String) -> ChatExchange {
  ChatExchange(
    segment: "s1", opening: ChatSegmentOpening(through: through, playbook: "p", stableContext: "stable"), sections: ChatHeldSections(),
    messages: [PromptMessage(.user, "turn")])
}

private func record(_ exchange: ChatExchange, in store: VaultStore) async throws {
  try await store.write { transaction in try ChatContextExchangeLog.record(exchange, reply: UUID(), session: ChatWorld.session, in: transaction.database) }
}

private func transcript(_ ordinals: ClosedRange<Int>) -> String {
  ordinals.map { "\($0.isMultiple(of: 2) ? "assistant" : "user"): Message \($0)." }.joined(separator: "\n\n")
}

private func faultAMessageElsewhere(in store: VaultStore) async throws {
  _ = try await store.write { transaction in
    try transaction.database.execute(
      sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')",
      arguments: [ChatMessageRow.databaseTableName, ProjectionFaults.key(NovelForgeKey.chatMessage(UUID()))])
  }
}

private func exchanges(in store: VaultStore) async throws -> [UUID: ChatExchange] {
  try await store.read { transaction in try ChatContextExchangeLog.load(session: ChatWorld.session, in: transaction.database) }
}

@Suite("Chat compaction window", .timeLimit(.minutes(3)))
struct ChatCompactionWindowTests {
  @Test func shouldKeepSixMessagesAndTwelveWithinTheBudgetAndFoldBeyond() async throws {
    for (count, folds) in [(6, false), (12, false), (13, true)] {
      let (_, store) = try ChatWorld.store()
      try await World.write(try World.turns(count), in: store)
      let plan = try await World.window(in: store).foldPlan()
      #expect((plan != nil) == folds, "\(count)")
      #expect(plan.map { $0.folded.map(\.record.id) } ?? [] == (folds ? (1...7).map(World.id) : []), "\(count)")
      #expect(plan?.kept.map(\.record.id) ?? [] == (folds ? (8...13).map(World.id) : []), "\(count)")
    }
  }

  @Test func shouldFoldSevenMessagesOverTheBudgetCountingStoredTokensFirst() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(6, tokens: 1_000) + [try message(7, tokens: 0)], in: store)
    #expect(try await World.window(in: store).foldPlan() == nil)
    #expect(try await World.window(in: store).foldPlan(historyBudget: 5_999)?.folded.map(\.record.id) == [World.id(1)])
    let (_, counted) = try ChatWorld.store()
    try await World.write(try World.turns(6) + [try message(7, content: String(repeating: "a ", count: 6_000))], in: counted)
    #expect(try await World.window(in: counted).foldPlan()?.folded.map(\.record.id) == [World.id(1)])
  }

  @Test func shouldSaturateStoredTokenCountsInsteadOfTrapping() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write([try message(1, tokens: .max)] + (try World.turns(6, from: 2, tokens: 1)), in: store)
    #expect(try await World.window(in: store).foldPlan()?.folded.count == 1)
  }

  @Test func shouldWriteTheTranscriptWithoutRefusedAuthorTextAndCoverEveryFoldedMessage() async throws {
    let (_, store) = try ChatWorld.store()
    let prior = try ChatWorld.summary(covering: [World.id(90)])
    let refused = try message(1, content: "the schoolgirl looked sexy in the doorway")
    let reply = try message(2, role: .assistant, content: "the schoolgirl looked sexy", question: ["question": "Which?", "answers": [["title": "A"], ["title": "B"]]])
    try await World.write([refused, reply] + (try World.turns(11, from: 3)), summary: prior, in: store)
    let plan = try #require(try await World.window(in: store).foldPlan())
    #expect(plan.priorSummary == prior.text)
    #expect(plan.transcript.jsEquals("assistant: the schoolgirl looked sexy\n\n" + transcript(3...7)))
    #expect(plan.covered == [World.id(90)] + (1...7).map(World.id))
    #expect(plan.novel == ChatWorld.novel)
  }

  @Test func shouldLeaveUnreadableMessagesOutOfTheWindowAndSkipUnreadablePassagesFromTheFold() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(7), in: store)
    try await ChatWorld.appendRaw(NovelForgeKey.chatMessage(UUID()), ChatWorld.item(["role": "user"]), in: store)
    try await ChatWorld.appendRaw(NovelForgeKey.chatMessage(UUID()), ChatWorld.item(["role": "moderator", "content": "x", "content_mode": "standard"]), in: store)
    let unreadablePassage = ChatWorld.item(["role": "user", "content": "Look at this passage.", "contexts": "x", "content_mode": "standard"])
    let passageID = World.id(50)
    try await ChatWorld.appendRaw(NovelForgeKey.chatMessage(passageID), unreadablePassage, in: store)
    let window = try await World.window(in: store)
    #expect(window.messages.map(\.record.id) == (1...7).map(World.id) + [passageID])
    let passage = try #require(window.messages.last)
    #expect(window.render(passage, for: .standard) == [PromptMessage(.user, "Look at this passage.")])
    #expect(window.render(passage, for: .unrestricted).isEmpty)

    let (_, first) = try ChatWorld.store()
    try await ChatWorld.appendRaw(NovelForgeKey.chatMessage(passageID), unreadablePassage, in: first)
    try await World.write(try World.turns(12, from: 2), in: first)
    let plan = try #require(try await World.window(in: first).foldPlan())
    #expect(plan.folded.map(\.record.id) == [passageID] + (2...7).map(World.id))
    #expect(plan.transcript.jsEquals(transcript(2...7)))
    #expect(plan.covered.first == passageID)
  }

  @Test func shouldRaiseTheFoldForTheTurnTheNovelAndAnyUnrestrictedTextItSendsOrTheSessionIsKnownToHold() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    let window = try await World.window(in: store)
    let plan = try #require(window.foldPlan())
    #expect(window.lock == .unlocked)
    #expect(window.foldMode(plan, turn: .standard, novel: .standard) == .standard)
    #expect(window.foldMode(plan, turn: .unrestricted, novel: .standard) == .unrestricted)
    #expect(window.foldMode(plan, turn: .standard, novel: .unrestricted) == .unrestricted)

    try await ChatWorld.append(try message(14, role: .user, mode: .unrestricted), in: store)
    let locked = try await World.window(in: store)
    #expect(locked.lock == .locked)
    #expect(locked.foldMode(try #require(locked.foldPlan()), turn: .standard, novel: .standard) == .unrestricted)

    let hidden = ChatConversationWindow(session: ChatWorld.session, summary: nil, messages: window.messages, lock: .unavailable)
    #expect(hidden.foldMode(plan, turn: .standard, novel: .standard) == .standard)
    let (_, authored) = try ChatWorld.store()
    try await World.write([try message(1, mode: .unrestricted)] + (try World.turns(12, from: 2)), in: authored)
    let claimed = try await World.window(in: authored)
    let claimedPlan = try #require(claimed.foldPlan())
    let hiddenClaim = ChatConversationWindow(session: ChatWorld.session, summary: nil, messages: claimed.messages, lock: .unavailable)
    #expect(hiddenClaim.foldMode(claimedPlan, turn: .standard, novel: .standard) == .unrestricted)
  }

  @Test func shouldRaiseTheFoldForAPriorSummaryWhoseModeIsNotStandardAndHideItFromAStandardTurn() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(14), in: store)
    let raw = ChatWorld.item(["covered": .array([World.id(1).json]), "text": "Secret.", "content_mode": "mystery"])
    try await ChatWorld.appendRaw(NovelForgeKey.chatSummary(UUID()), raw, in: store)
    let window = try await World.window(in: store)
    #expect(window.summary?.record.text == "Secret.")
    #expect(window.history(for: .standard).first == PromptMessage(.user, "Conversation so far (compacted summary):\n\(unrestrictedSummaryPlaceholder)"))
    #expect(window.history(for: .unrestricted).first == PromptMessage(.user, "Conversation so far (compacted summary):\nSecret."))
    let hidden = ChatConversationWindow(session: ChatWorld.session, summary: window.summary, messages: window.messages, lock: .unavailable)
    #expect(hidden.foldMode(try #require(hidden.foldPlan()), turn: .standard, novel: .standard) == .unrestricted)
  }

  @Test func shouldSkipMessagesThatRenderBlank() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write([try message(1), try message(2, role: .assistant, content: "  \n")], in: store)
    let window = try await World.window(in: store)
    #expect(window.history(for: .standard) == [PromptMessage(.user, "Message 1.")])
    #expect(window.history(for: .unrestricted) == [PromptMessage(.user, "Message 1.")])
  }

  @Test func shouldCapAFoldByTranscriptTokensAndAlwaysFoldTheOldest() async throws {
    let (_, store) = try ChatWorld.store()
    let long = String(repeating: "a ", count: 2_000)
    try await World.write(try (1...30).map { try message($0, role: $0.isMultiple(of: 2) ? .assistant : .user, content: long) }, in: store)
    let plan = try #require(try await World.window(in: store).foldPlan())
    let cost = { (ordinal: Int) in countTokens("\(ordinal.isMultiple(of: 2) ? "assistant" : "user"): \(long)") }
    let spent = plan.folded.indices.reduce(0) { $0 + cost($1 + 1) }
    #expect(!plan.folded.isEmpty && plan.folded.count < 24)
    #expect(spent <= ChatFoldPlan.maxFoldTokens && spent + cost(plan.folded.count + 1) > ChatFoldPlan.maxFoldTokens)
    #expect(plan.kept.count == 30 - plan.folded.count)
    #expect(plan.covered == plan.folded.map(\.record.id))

    let (_, huge) = try ChatWorld.store()
    try await World.write([try message(1, content: String(repeating: "a ", count: 30_000))] + (try World.turns(12, from: 2)), in: huge)
    #expect(try await World.window(in: huge).foldPlan()?.folded.map(\.record.id) == [World.id(1)])
  }

  @Test func shouldHideUnrestrictedRepliesAndSummariesFromAStandardTurnOnly() async throws {
    let (_, store) = try ChatWorld.store()
    let author = try message(2, mode: .unrestricted)
    let modeless = try message(3, role: .assistant, content: "No mode.", mode: nil)
    let asked = try message(4, role: .assistant, content: "Pick one.", question: ["question": "Which?", "answers": [["title": "A"], ["title": "B"]]])
    let summary = try ChatWorld.summary(covering: [World.id(1)], mode: .unrestricted)
    try await World.write([try message(1), author, modeless, asked], summary: summary, in: store)
    let window = try await World.window(in: store)
    #expect(
      window.history(for: .standard) == [
        PromptMessage(.user, "Conversation so far (compacted summary):\n\(unrestrictedSummaryPlaceholder)"), PromptMessage(.user, "Message 2."),
        PromptMessage(.assistant, unrestrictedReplyPlaceholder), PromptMessage(.assistant, "Pick one.\n\n[Asked: Which? — options: A / B]"),
      ])
    #expect(
      window.history(for: .unrestricted) == [
        PromptMessage(.user, "Conversation so far (compacted summary):\n\(summary.text)"), PromptMessage(.user, "Message 2."), PromptMessage(.assistant, "No mode."),
        PromptMessage(.assistant, "Pick one.\n\n[Asked: Which? — options: A / B]"),
      ])
    #expect(window.watermark == summary.ref.key.rawValue)
  }

  @Test func shouldReadAMissingSessionAsAnEmptyWindowAndAFaultedOneAsAnError() async throws {
    let (_, store) = try ChatWorld.store()
    let empty = try await World.window(in: store)
    #expect(empty.messages.isEmpty && empty.summary == nil && empty.lock == .unlocked && empty.watermark.isEmpty)
    let result = try await World.compact(store: store, provider: ScriptedModelProvider())
    #expect(result.outcome == .kept)

    let (_, faulted) = try ChatWorld.store()
    try await World.write(try World.turns(2), in: faulted)
    _ = try await faulted.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')",
        arguments: [ChatTranscriptRow.databaseTableName, ProjectionFaults.key(NovelForgeKey.chatSession(ChatWorld.session))])
    }
    do {
      _ = try await World.compact(store: faulted, provider: ScriptedModelProvider())
      Issue.record("expected the window to be unavailable")
    } catch let error as ChatCompactionError {
      guard case .windowUnavailable(let faults) = error else { throw error }
      #expect(!faults.isEmpty)
    }
  }
}

@Suite("Chat compaction", .timeLimit(.minutes(3)))
struct ChatCompactionTests {
  @Test func shouldAppendACumulativeSummaryForgetTheExchangeLogAndReturnTheKeptWindow() async throws {
    let (_, store) = try ChatWorld.store()
    let prior = try ChatWorld.summary(covering: [World.id(90), World.id(91)])
    try await World.write(try World.turns(13), summary: prior, in: store)
    try await record(exchange(through: prior.ref.key.rawValue), in: store)
    let provider = ScriptedModelProvider(calls: [World.reply("They chose the heir.")])
    let result = try await World.compact(store: store, provider: provider)

    guard case .folded(let id, .standard, let callIDs) = result.outcome else {
      Issue.record("expected a fold, got \(result.outcome)")
      return
    }
    #expect(callIDs.count == 1)
    let written = try #require(try await World.summaries(in: store).first { $0.id == id })
    #expect(written.covered == [World.id(90), World.id(91)] + (1...7).map(World.id))
    #expect(written.text == "They chose the heir." && written.contentMode == .known(.standard))
    #expect(result.window.summary?.record == written)
    #expect(result.window.messages.map(\.record.id) == (8...13).map(World.id))
    #expect(try await exchanges(in: store).isEmpty)

    let request = try #require(provider.requests.first)
    #expect(request.model == "claude-haiku-5-5")
    #expect(request.system.map(\.text) == [chatCompactSystem])
    let text = "Prior summary:\n\(prior.text)\n\nTranscript to fold in:\n\(transcript(1...7))"
    #expect(request.messages.count == 1 && request.messages.first?.text.jsEquals(World.sent(text, in: request)) == true)
  }

  @Test func shouldFoldAStandardSessionStandardWhileAnUnrelatedChatRowIsFaultedAndLeaveItUnlocked() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    try await faultAMessageElsewhere(in: store)
    #expect(try await World.window(in: store).lock == .unavailable)
    let provider = ScriptedModelProvider(calls: [World.reply("Summary.")])
    let result = try await World.compact(store: store, provider: provider)
    guard case .folded(_, .standard, _) = result.outcome else {
      Issue.record("expected a standard fold, got \(result.outcome)")
      return
    }
    #expect(provider.requests.first?.model == "claude-haiku-5-5")
    #expect(result.window.summary?.record.contentMode == .known(.standard))
    #expect(result.window.history(for: .standard).first == PromptMessage(.user, "Conversation so far (compacted summary):\nSummary."))
    _ = try await store.write { transaction in try transaction.database.execute(sql: "DELETE FROM nf_derived_fault") }
    #expect(try await World.window(in: store).lock == .unlocked)
  }

  @Test func shouldAcceptAnUnrestrictedSummaryOnlyTheSuppliedScopeWouldRefuse() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    let result = try await World.compact(
      turn: World.turn(.unrestricted), store: store, provider: ScriptedModelProvider(calls: [World.reply("the schoolgirl looked sexy in the doorway")]))
    guard case .folded(_, .unrestricted, _) = result.outcome else {
      Issue.record("expected an unrestricted fold, got \(result.outcome)")
      return
    }
  }

  @Test func shouldRouteAnUnrestrictedFoldStrictlyWithTheHardLineSystemLine() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    let provider = ScriptedModelProvider(calls: [World.reply("Summary.")])
    let result = try await World.compact(turn: World.turn(.unrestricted), store: store, provider: provider)
    guard case .folded(_, .unrestricted, _) = result.outcome else {
      Issue.record("expected an unrestricted fold, got \(result.outcome)")
      return
    }
    let request = try #require(provider.requests.first)
    #expect(request.model == World.unrestrictedModel)
    #expect(request.system.map(\.text) == [hardLineSystemLine, chatCompactSystem])
    #expect(try await World.summaries(in: store).first?.contentMode == .known(.unrestricted))
  }

  @Test func shouldSkipAnUnrestrictedFoldTheHardLineRefusesAndWriteNothing() async throws {
    let (_, store) = try ChatWorld.store()
    let turns = try [message(1), message(2, role: .assistant, content: "a child and intercourse in one line")] + World.turns(11, from: 3)
    try await World.write(turns, in: store)
    try await record(exchange(through: "elsewhere"), in: store)
    let provider = ScriptedModelProvider()
    let result = try await World.compact(turn: World.turn(.unrestricted), store: store, provider: provider)
    guard case .refused(let hit, let callIDs) = result.outcome else {
      Issue.record("expected a refusal, got \(result.outcome)")
      return
    }
    #expect(hit.source == "The earlier conversation" && hit.rule == .minorWithExplicitAct && callIDs.isEmpty)
    #expect(provider.requests.isEmpty)
    #expect(try await World.summaries(in: store).isEmpty)
    #expect(result.window.messages.count == 13)
    #expect(try await exchanges(in: store).isEmpty)
  }

  @Test func shouldSkipAnUnrestrictedFoldWhoseSummaryTheHardLineRefuses() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    try await record(exchange(through: ""), in: store)
    let provider = ScriptedModelProvider(calls: [World.reply("nothing but loli art")])
    let result = try await World.compact(turn: World.turn(.unrestricted), store: store, provider: provider)
    guard case .refused(let hit, let callIDs) = result.outcome else {
      Issue.record("expected a refusal, got \(result.outcome)")
      return
    }
    #expect(hit.source == "The generated text" && hit.rule == .standaloneTerm && callIDs.count == 1)
    #expect(try await World.summaries(in: store).isEmpty)
    #expect(try await exchanges(in: store).count == 1)
  }

  @Test func shouldSkipAnUnrestrictedFoldWhoseRepairTheRouterRefuses() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    let provider = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("not json: a child and intercourse in one line"), World.reply("Summary.")])
    let result = try await World.compact(turn: World.turn(.unrestricted), store: store, provider: provider)
    guard case .refused(let hit, let callIDs) = result.outcome else {
      Issue.record("expected a refusal, got \(result.outcome)")
      return
    }
    #expect(hit == HardLineHit(rule: .minorWithExplicitAct, source: "The request", sourceRefs: []) && callIDs.count == 1)
    #expect(provider.requests.count == 1)
    #expect(provider.requests.first?.system.map(\.text) == [hardLineSystemLine, chatCompactSystem])
    #expect(try await World.summaries(in: store).isEmpty)
  }

  @Test func shouldNotScreenAStandardFold() async throws {
    let (_, store) = try ChatWorld.store()
    let turns = try [message(1), message(2, role: .assistant, content: "a child and intercourse in one line")] + World.turns(11, from: 3)
    try await World.write(turns, in: store)
    let result = try await World.compact(store: store, provider: ScriptedModelProvider(calls: [World.reply("nothing but loli art")]))
    guard case .folded(_, .standard, _) = result.outcome else {
      Issue.record("expected a standard fold, got \(result.outcome)")
      return
    }
  }

  @Test func shouldPropagateRoutingAndModelFailuresWithoutWriting() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(13), in: store)
    let router = TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic), credentials: StaticNoCredentials(), store: store, requestGuard: { _ in nil })
    await #expect(throws: ChatCompactionError.self) {
      try await ChatCompaction.compactIfNeeded(session: ChatWorld.session, turn: World.turn(), store: store, router: router)
    }
    let failing = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("not json"), ScriptedModelProvider.reply("still not json")])
    do {
      _ = try await World.compact(store: store, provider: failing)
      Issue.record("expected the fold to fail")
    } catch let error as ChatCompactionError {
      guard case .model(_, let callIDs) = error else { throw error }
      #expect(callIDs.count == 2)
    }
    #expect(try await World.summaries(in: store).isEmpty)
  }

  @Test func shouldForgetTheWholeLogWhenAnySegmentOpenedUnderAnotherWatermark() async throws {
    let (_, store) = try ChatWorld.store()
    try await World.write(try World.turns(3), in: store)
    try await record(exchange(through: ""), in: store)
    _ = try await World.compact(store: store, provider: ScriptedModelProvider())
    #expect(try await exchanges(in: store).count == 1)

    let synced = try ChatWorld.summary(covering: [World.id(1)])
    try await ChatWorld.append(synced, in: store)
    try await record(exchange(through: synced.ref.key.rawValue), in: store)
    let result = try await World.compact(store: store, provider: ScriptedModelProvider())
    #expect(result.outcome == .kept && result.window.watermark == synced.ref.key.rawValue)
    #expect(try await exchanges(in: store).isEmpty)
  }
}

private struct StaticNoCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? { nil }
}
