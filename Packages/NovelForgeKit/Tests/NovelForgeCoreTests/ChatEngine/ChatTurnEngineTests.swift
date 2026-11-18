import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private func lastUser(_ request: ModelRequest) -> String {
  request.messages.last?.text ?? ""
}

// apps/novel-forge-server/src/modules/refinement/chat.service.ts:268-411 over the store, against a scripted model
@Suite("Chat turn engine", .timeLimit(.minutes(3)))
struct ChatTurnEngineTests {
  @Test func shouldRunATurnWithALookupRoundAndStageItsChangesInOneReply() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [
      World.reply(("reply", World.text("Let me check Mara first.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#)),
      World.reply(("reply", World.text("Done — I noted it.\nMore below.")), ("changeSet", "[\(World.maraThief),\(World.removeRise)]")),
    ])
    let (named, settled) = (Signal(), Signal())
    let upkeep = RecordedUpkeep(titleCalls: [UUID()], recorded: named)
    let engine = try await World.engine(book.store, provider: provider, upkeep: upkeep, turnsWait: settled)
    // the turn asks once the naming has recorded its end, so the naming finishes first
    let gate = Task {
      await named.wait()
      await engine.namingsSettled()
      settled.raise()
    }
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    let outcome = await handle.outcome()
    await gate.value
    let events = await World.events(handle)

    let replyID = try World.reply(of: outcome)
    #expect(replyID == handle.turn)
    let messages = try await World.messages(in: book.store)
    #expect(messages.map(\.role) == [.known(.user), .known(.assistant)])
    let (user, reply) = (messages[0], messages[1])
    #expect(user.id == handle.userMessage && user.content == World.message && user.pace == .known(.balanced) && user.contentMode == .known(.standard))
    #expect(reply.answers == user.id && reply.content == "Done — I noted it.\nMore below." && reply.contentMode == .known(.standard))
    let applied = try #require(reply.appliedProposal)
    let card = try #require(reply.cardProposal)
    let (appliedCard, suggestions) = (try await book.proposal(applied).card, try await book.proposal(card).card)
    #expect(appliedCard.message == replyID && suggestions.message == replyID)
    #expect(try await book.entity("mara")?.status == "thief")
    #expect(try await World.proposals(of: replyID, in: book.store).count == 2)
    // two chat calls, and the session's name beside the turn, whose ids joined the reply because it finished first
    #expect(reply.modelCalls?.count == 3)
    #expect(upkeep.named == [user.id])
    let sources = reply.trace?.objectValue?["sources"]?.arrayValue ?? []
    #expect(sources.map { $0.objectValue?["tool"] } == [.string("get_entity")])

    #expect(provider.requests.count == 2)
    #expect(lastUser(provider.requests[1]).hasPrefix("Lookup results:\n### get_entity\n"))
    #expect(provider.requests[1].system.count(where: \.endsStablePrefix) == 1)
    #expect(events.first == .user(message: user.id) && events.last == .done(reply: replyID))
    #expect(events.contains(.lookup(TurnLookupEvent(round: 0, tool: "get_entity", args: OrderedJSONObject([("entityKey", .string("mara"))]), status: .running))))
    #expect(events.contains(.lookup(TurnLookupEvent(round: 0, tool: "get_entity", args: OrderedJSONObject([("entityKey", .string("mara"))]), status: .ok))))
    #expect(events.contains(.reset))

    // the reply's transaction ended the local turn, kept the exchange and the last request
    #expect(try await World.localTurn(handle.turn, in: book.store) == nil)
    #expect(try await World.record(handle.turn, in: book.store) == nil)
    #expect(try await World.steps(of: replyID, in: book.store) == [])
    let exchanges = try await book.store.read { try ChatContextExchangeLog.load(session: World.session, in: $0.database) }
    let exchange = try #require(exchanges[replyID])
    #expect(exchange.opening?.through == "")
    #expect(exchange.messages.count == 3 && exchange.messages[0].role == .user && exchange.messages[2].text.hasPrefix("Lookup results:"))
    let inspection = try #require(try await book.store.chatCallInspection(reply: replyID))
    #expect(inspection.messages.count == provider.requests[1].messages.count && inspection.stablePrefixEnd == 2)
    #expect(try await engine.activity(session: World.session) == .idle)
  }

  // chat.service.ts:375-394
  @Test func shouldRewriteANegationOnceAndStageTheRevisedChangeSet() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
    let negated = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
    let revised = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She travels light to the tower."}"#
    let provider = ScriptedModelProvider(calls: [
      World.reply(("reply", World.text("Dropped the dagger.")), ("changeSet", "[\(negated)]")),
      World.reply(("reply", World.text("Rewrote it.")), ("changeSet", "[\(revised)]")),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Take her dagger away.", session: World.session, novel: novel)
    let replyID = try World.reply(of: await handle.outcome())

    #expect(provider.requests.count == 2)
    #expect(lastUser(provider.requests[1]).hasPrefix("Your changeSet removes things by stating their absence"))
    let reply = try #require(try await World.messages(in: book.store).last)
    #expect(reply.id == replyID && reply.content.hasPrefix("Rewrote it."))
    let staged = try await World.proposals(of: replyID, in: book.store)
    #expect(staged.flatMap(\.card.warnings).isEmpty)
    #expect(staged.flatMap { $0.card.changeSet.compactMap(\.op) }.map(\.type) == [.entityUpsert])
    let exchange = try #require(try await book.store.read { try ChatContextExchangeLog.load(session: World.session, in: $0.database) }[replyID])
    #expect(exchange.messages.count == 3)
  }

  @Test func shouldKeepTheFlaggedChangeSetWhenTheNegationFixFails() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
    let negated = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Dropped the dagger.")), ("changeSet", "[\(negated)]")), [.failure(.authentication)]])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Take her dagger away.", session: World.session, novel: novel)
    let replyID = try World.reply(of: await handle.outcome())

    let reply = try #require(try await World.messages(in: book.store).last)
    #expect(reply.held == TurnHoldReason.warnings.rawValue && reply.appliedProposal == nil)
    #expect(try await World.proposals(of: replyID, in: book.store).flatMap(\.card.warnings).contains { $0.contains("by stating its absence") })
    let exchange = try #require(try await book.store.read { try ChatContextExchangeLog.load(session: World.session, in: $0.database) }[replyID])
    #expect(exchange.messages.count == 1)
    #expect(reply.modelCalls?.count == 2)
  }

  // chat.service.ts:285-290: refused before it is saved
  @Test func shouldRefuseAnUnrestrictedMessageTheHardLineHoldsBeforeSavingIt() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider()
    let engine = try await World.engine(book.store, provider: provider)
    await #expect {
      _ = try await engine.send(
        "the schoolgirl looked sexy in the doorway", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .unrestricted))
    } throws: { error in
      guard case ChatTurnError.hardLine(let code, _) = error else { return false }
      return code == "AI_015"
    }
    #expect(try await World.messages(in: book.store).isEmpty)
    #expect(try await book.store.pendingLocalTurns().isEmpty)
    #expect(provider.requests.isEmpty)
  }

  // model-router.service.ts:761-781 and :307: the refused sentence is never shown and the turn fails
  @Test func shouldFailAnUnrestrictedTurnWhoseReplyTheHardLineRefuses() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("She waited. The schoolgirl looked sexy in the doorway.")))])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Describe the doorway.", session: World.session, novel: book.novel, choices: ChatTurnChoices(contentMode: .unrestricted))
    let outcome = await handle.outcome()
    let events = await World.events(handle)

    guard case .failed(let failure) = outcome else {
      Issue.record("expected a failure, got \(outcome)")
      return
    }
    #expect(failure.code == "AI_015")
    #expect(provider.requests.first?.model == CompactionWorld.unrestrictedModel)
    #expect(provider.requests.first?.system.first?.text == hardLineSystemLine)
    let shown = events.compactMap { event -> String? in
      guard case .delta(let text) = event else { return nil }
      return text
    }.joined()
    #expect(!shown.contains("schoolgirl"))
    #expect(events.last == .error(failure))
    let messages = try await World.messages(in: book.store)
    #expect(messages.count == 1 && messages[0].contentMode == .known(.unrestricted))
    let local = try #require(try await World.localTurn(handle.turn, in: book.store))
    #expect(local.state == .failed && local.failure == failure)
    let frames = try await book.store.localTurnFrames(handle.turn)
    #expect(frames.last?.decoded == .error(failure))
    #expect(try await engine.activity(session: World.session) == .ended(local))
  }

  // chat.dto.ts:473
  @Test func shouldRefuseAMessageOverTwoHundredThousandCharactersAndAnEmptyOne() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    await #expect {
      _ = try await engine.send(String(repeating: "a", count: 200_001), session: World.session, novel: book.novel)
    } throws: { error in
      guard case ChatTurnError.messageTooLong(let limit) = error else { return false }
      return limit == 200_000
    }
    await #expect {
      _ = try await engine.send("  \n", session: World.session, novel: book.novel)
    } throws: { ($0 as? ChatTurnError)?.code == "CHT_012" }
    #expect(try await World.messages(in: book.store).isEmpty)
  }

  @Test func shouldRefuseATurnInAnArchivedOrMissingChat() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    await #expect { _ = try await engine.send("Hi.", session: UUID(), novel: book.novel) } throws: { ($0 as? ChatTurnError)?.code == "CHT_001" }
    var edit = ChatSessionEdit()
    edit.setStatus(.archived)
    let changes = edit
    try await book.run { _ = try ChatSessionRecord.edit(id: World.session, changes, in: &$0) }
    await #expect { _ = try await engine.send("Hi.", session: World.session, novel: book.novel) } throws: { ($0 as? ChatTurnError)?.code == "CHT_002" }
  }

  @Test func shouldSayClearlyWhenTheProviderFindsTheRequestTooLarge() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [[.failure(.invalidRequest("prompt is too long: 250000 tokens > 200000 maximum"))]])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Summarise everything.", session: World.session, novel: book.novel)
    #expect(await handle.outcome() == .failed(TurnFailure(code: ChatTurnFailures.requestTooLargeCode, message: ChatTurnFailures.requestTooLarge)))
  }

  // passage-context.ts:92 and chat.dto.ts:234-264
  @Test func shouldAnchorPassageCommentsAndRefuseOnesThatNoLongerMatch() async throws {
    let book = try await World.book(workspace: true)
    let novel = book.novel
    let draft = try #require(try await book.store.read { try ChatTurnDrafts.read([3], novel: novel, in: $0)[3] })
    let quote = StagingText.fear
    let start = StagingText.body.jsIndexOf(quote)
    let passage = ChatTurnPassage(
      chapter: 3, draftId: draft.identity, revision: draft.generation, start: start, end: start + quote.jsLength, passageHash: passageHash(quote), quote: quote,
      comment: " Make him braver. ")
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("He could be.")))])
    let engine = try await World.engine(book.store, provider: provider)

    var broken = passage
    broken.passageHash = "ABC"
    await #expect { _ = try await engine.send("", passages: [broken], session: World.session, novel: novel) } throws: {
      ($0 as? ChatTurnError)?.code == "chat_turn.invalid_passage"
    }
    var moved = passage
    moved.quote = "He was brave."
    moved.end = moved.start + moved.quote.jsLength
    moved.passageHash = passageHash(moved.quote)
    await #expect { _ = try await engine.send("", passages: [moved], session: World.session, novel: novel) } throws: { ($0 as? ChatTurnError)?.code == "CHT_009" }

    let handle = try await engine.send("", passages: [passage], session: World.session, novel: novel)
    _ = try World.reply(of: await handle.outcome())
    let user = try #require(try await World.messages(in: book.store).first)
    #expect(user.passageContexts?.map(\.comment) == ["Make him braver."])
    #expect(lastUser(provider.requests[0]).contains("Passage comments:\n1. Chapter 3"))
  }

  // The F19b rule: a turn reads the prose the author sees, this device's working copy over the head, not a revision up to 600 s old
  @Test func shouldReadADraftThroughThisDevicesWorkingCopy() async throws {
    let book = try await World.book(workspace: true)
    let unsaved = "Mara carries a dagger to the tower."
    _ = try await book.save(3, unsaved, summary: "It turns.", base: try await book.head(3))
    #expect(try await book.draftContent(3)?.body == StagingText.body)
    let provider = ScriptedModelProvider(calls: [
      World.reply(("reply", World.text("Reading.")), ("lookups", #"[{"tool":"get_draft","args":{"chapter":3}}]"#)), World.reply(("reply", World.text("Got it."))),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    _ = try World.reply(of: await engine.send("Look at chapter 3.", session: World.session, novel: book.novel).outcome())
    #expect(lastUser(provider.requests[1]).contains(unsaved))
    #expect(!lastUser(provider.requests[1]).contains(StagingText.fear))
  }

  // chat-compaction.service.ts:118-178 before the turn routes; the fold's ids join the reply
  @Test func shouldFoldTheWindowBeforeTheTurnAndCarryTheFoldsCallIDs() async throws {
    let book = try await World.book()
    let turns = try CompactionWorld.turns(13)
    try await book.run { transaction in for message in turns { _ = try message.append(in: &transaction) } }
    let provider = ScriptedModelProvider(calls: [CompactionWorld.reply("They planned the heist."), World.reply(("reply", World.text("Noted.")))])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("What next?", session: World.session, novel: book.novel)
    let replyID = try World.reply(of: await handle.outcome())

    let summary = try #require(try await CompactionWorld.summaries(in: book.store).first)
    #expect(summary.covered == (1...7).map(CompactionWorld.id))
    #expect(provider.requests.count == 2)
    #expect(provider.requests[1].messages.first?.text == "Conversation so far (compacted summary):\nThey planned the heist.")
    let reply = try #require(try await World.messages(in: book.store).last)
    #expect(reply.id == replyID && reply.modelCalls?.count == 2)
    let exchange = try #require(try await book.store.read { try ChatContextExchangeLog.load(session: World.session, in: $0.database) }[replyID])
    #expect(exchange.opening?.through == summary.ref.key.rawValue)
  }

  @Test func shouldContinueTheSegmentTheLastReplyOpenedOnTheNextTurn() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("First."))), World.reply(("reply", World.text("Second.")))])
    let engine = try await World.engine(book.store, provider: provider)
    _ = try World.reply(of: await engine.send("One.", session: World.session, novel: book.novel).outcome())
    _ = try World.reply(of: await engine.send("Two.", session: World.session, novel: book.novel).outcome())

    let (first, second) = (provider.requests[0], provider.requests[1])
    #expect(second.system == first.system)
    #expect(Array(second.messages.prefix(first.messages.count - 1)).map(\.text) == Array(first.messages.dropLast()).map(\.text))
    #expect(second.messages[first.messages.count - 1].text.hasPrefix("Where the story stands now:"))
    #expect(second.messages[first.messages.count].text == "First.")
    #expect(lastUser(second).contains("Unchanged since the previous turn."))
  }
}
