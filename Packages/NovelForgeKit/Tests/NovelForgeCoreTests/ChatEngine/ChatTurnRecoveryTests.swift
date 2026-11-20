import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private let stalled: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it"#), .delay(.seconds(120))]

private func answered(_ text: String, changeSet: String? = nil) -> [ScriptedModelProvider.Step] {
  guard let changeSet else { return World.reply(("reply", World.text(text))) }
  return World.reply(("reply", World.text(text)), ("changeSet", changeSet))
}

/// Saves a turn as `send` does up to its first model call, without running it: the state a crash right after the author's message leaves.
private func begun(_ content: String, engine: ChatTurnEngine, book: ChapterBook) async throws -> ChatTurnBasis {
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

private func settled(_ reply: String, changeSet: String) throws -> ChatTurnSettled {
  let objects = try #require(try OrderedJSON(parsing: changeSet).arrayValue).compactMap(\.objectValue)
  return ChatTurnSettled(reply: reply, changeSet: objects, question: nil, warnings: [], trace: .object([:]), calls: [], exchangeMessages: [])
}

private func stagingRequest(_ basis: ChatTurnBasis, _ answer: ChatTurnSettled) -> TurnStagingRequest {
  TurnStagingRequest(
    novel: basis.novel, session: basis.session, reply: basis.reply, replyText: answer.reply, changeSet: answer.changeSet, authorMessage: basis.authorWords,
    mode: basis.sessionMode, justDiscussing: false, organise: basis.organise, contexts: [], warnings: [], run: nil, now: Date())
}

private func expectOneAnsweredTurn(_ book: ChapterBook, reply: UUID) async throws {
  let messages = try await World.messages(in: book.store)
  #expect(messages.map(\.role) == [.known(.user), .known(.assistant)])
  #expect(messages.last?.id == reply)
  let proposals = try await World.proposals(of: reply, in: book.store)
  #expect(proposals.count(where: { $0.application?.automatic == true }) <= 1)
  #expect(try await book.store.read { try ProposalRecord.listing(in: $0).entries.count } == proposals.count)
  #expect(try await book.store.pendingLocalTurns().isEmpty)
}

@Suite("Chat turn recovery", TestTimeLimit.standard)
struct ChatTurnRecoveryTests {
  @Test func shouldEndACancelledTurnWithoutAReplyAndAnswerItOnceOnRetry() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [stalled, answered("Here it is.")])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Plan the heist.", session: World.session, novel: book.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    engine.cancel(turn: handle.turn)
    #expect(await handle.outcome() == .cancelled)
    #expect(try await World.messages(in: book.store).count == 1)
    #expect(try await World.localTurn(handle.turn, in: book.store)?.state == .cancelled)

    let retried = try await engine.retry(turn: handle.turn)
    #expect(retried.turn == handle.turn && retried.userMessage == handle.userMessage)
    let reply = try World.reply(of: await retried.outcome())
    try await expectOneAnsweredTurn(book, reply: reply)
    #expect(try await World.messages(in: book.store).last?.answers == handle.userMessage)
  }

  @Test func shouldFailATurnOnAModelErrorAndAnswerTheSameMessageOnRetry() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [[.failure(.authentication)], answered("Second time lucky.", changeSet: "[\(World.maraThief)]")])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    guard case .failed(let failure) = await handle.outcome() else {
      Issue.record("expected a failure")
      return
    }
    #expect(failure.code == "model.authentication")
    #expect(try await engine.activity(session: World.session) == .ended(try #require(try await World.localTurn(handle.turn, in: book.store))))
    await #expect { _ = try await engine.send("Again.", session: UUID(), novel: book.novel) } throws: { ($0 as? ChatTurnError)?.code == "CHT_001" }

    let reply = try World.reply(of: await engine.retry(turn: handle.turn).outcome())
    try await expectOneAnsweredTurn(book, reply: reply)
    #expect(try await book.entity("mara")?.status == "thief")
  }

  @Test func shouldRefuseASecondTurnInAChatWhileOneRuns() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await engine.send("One.", session: World.session, novel: book.novel)
    await #expect { _ = try await engine.send("Two.", session: World.session, novel: book.novel) } throws: { ($0 as? ChatTurnError)?.code == "chat_turn.running" }
    engine.cancel(turn: handle.turn)
    #expect(await handle.outcome() == .cancelled)
  }

  // A crash right after the author's message: the next launch resumes the turn from the start.
  @Test func shouldResumeATurnInterruptedBeforeItsFirstAnswer() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Plan the heist.", session: World.session, novel: book.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)
    #expect(try await first.activity(session: World.session) == .interrupted(try #require(try await World.localTurn(handle.turn, in: book.store))))

    let provider = ScriptedModelProvider(calls: [answered("Resumed.")])
    let upkeep = RecordedUpkeep()
    let relaunched = try await World.engine(book.store, provider: provider, upkeep: upkeep)
    let handles = try await relaunched.resumeInterruptedTurns()
    #expect(upkeep.forgot == 1)
    #expect(handles.map(\.turn) == [handle.turn])
    let events = await World.events(handles[0])
    #expect(events.first == .reset)
    try await expectOneAnsweredTurn(book, reply: try World.reply(of: await handles[0].outcome()))
    #expect(provider.requests.count == 1)
  }

  // A crash after a lookup round was saved: the resumed turn asks again from that round, not from the start.
  @Test func shouldResumeFromTheLastSavedLookupRound() async throws {
    let book = try await World.book()
    let lookup = World.reply(("reply", World.text("Checking.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#))
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [lookup, stalled]))
    let handle = try await first.send("Who is Mara?", session: World.session, novel: book.novel)
    let store = book.store
    try await World.eventually("the lookup round is saved") { try await store.localTurn(handle.turn)?.savedRounds == 1 }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)

    let provider = ScriptedModelProvider(calls: [answered("She is a thief.")])
    let handles = try await World.engine(book.store, provider: provider).resumeInterruptedTurns()
    let reply = try World.reply(of: await handles[0].outcome())
    try await expectOneAnsweredTurn(book, reply: reply)
    #expect(provider.requests.count == 1)
    #expect(provider.requests[0].messages.last?.text.hasPrefix("Lookup results:\n### get_entity") == true)
    let trace = try #require(try await World.messages(in: book.store).last?.trace)
    #expect(trace.objectValue?["sources"]?.arrayValue?.count == 1)
  }

  // A crash after the answer was settled, after staging wrote its changes, or after what it staged was saved: no model call, nothing applied twice.
  @Test func shouldFinishASettledTurnWithoutAskingAgainOrApplyingTwice() async throws {
    let changeSet = "[\(World.maraThief),\(World.removeRise)]"
    for boundary in ["settled", "staged", "recorded"] {
      let book = try await World.book()
      let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
      let basis = try await begun(World.message, engine: engine, book: book)
      let answer = try settled("Done — I noted it.", changeSet: changeSet)
      try await book.run { try ChatTurnRecords.settle(basis.turn, answer, in: $0.database) }
      var staging: TurnStagingResult?
      if boundary != "settled" { staging = try await book.store.stageTurn(stagingRequest(basis, answer)) }
      if boundary == "recorded", let staging {
        let recorded = ChatTurnStaged(
          appliedProposal: staging.appliedProposal, cardProposal: staging.cardProposal, applyNote: staging.applyNote, held: staging.held?.rawValue,
          replyNote: staging.replyNote)
        try await book.run { try ChatTurnRecords.stage(basis.turn, recorded, in: $0.database) }
      }

      let provider = ScriptedModelProvider()
      let handles = try await World.engine(book.store, provider: provider).resumeInterruptedTurns()
      #expect(handles.count == 1, "\(boundary)")
      let reply = try World.reply(of: await handles[0].outcome())
      #expect(reply == basis.reply, "\(boundary)")
      #expect(provider.requests.isEmpty, "\(boundary)")
      try await expectOneAnsweredTurn(book, reply: reply)
      let record = try #require(try await World.messages(in: book.store).last)
      #expect(record.appliedProposal != nil && record.cardProposal != nil, "\(boundary)")
      if let staging { #expect(record.appliedProposal == staging.appliedProposal && record.cardProposal == staging.cardProposal, "\(boundary)") }
      #expect(try await World.proposals(of: reply, in: book.store).count == 2, "\(boundary)")
    }
  }

  // A crash between the applied side and the cards that were to follow it: the applied changes stand once and the reply says the suggestions are missing.
  @Test func shouldSayTheSuggestionsAreMissingWhenOnlyTheAppliedSideWasStaged() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let basis = try await begun(World.message, engine: engine, book: book)
    let answer = try settled("Done — I noted it.", changeSet: "[\(World.maraThief),\(World.removeRise)]")
    try await book.run { try ChatTurnRecords.settle(basis.turn, answer, in: $0.database) }
    let directOnly = try settled("Done — I noted it.", changeSet: "[\(World.maraThief)]")
    let applied = try #require(try await book.store.stageTurn(stagingRequest(basis, directOnly)).appliedProposal)
    try await book.run { try TurnStagingMarks.record(.applied(proposal: applied, cardsFollow: true), reply: basis.reply, session: basis.session, in: $0.database) }

    let handles = try await World.engine(book.store, provider: ScriptedModelProvider()).resumeInterruptedTurns()
    let reply = try World.reply(of: await handles[0].outcome())
    let record = try #require(try await World.messages(in: book.store).last)
    #expect(record.id == reply && record.appliedProposal == applied && record.cardProposal == nil && record.applyNote == cardsUnsavedNote)
  }

  // What staging itself records: the applied side says whether cards follow it, and the cards say which proposal holds them
  @Test func shouldRecordWhichStagingTransactionsCommitted() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let direct = try await begun(World.message, engine: engine, book: book)
    let alone = try settled("Done — I noted it.", changeSet: "[\(World.maraThief)]")
    try await book.run { try ChatTurnRecords.settle(direct.turn, alone, in: $0.database) }
    let applied = try #require(try await book.store.stageTurn(stagingRequest(direct, alone)).appliedProposal)
    #expect(try await World.steps(of: direct.reply, in: book.store) == [.applied(proposal: applied, cardsFollow: false)])
    let handles = try await World.engine(book.store, provider: ScriptedModelProvider()).resumeInterruptedTurns()
    _ = try World.reply(of: await handles[0].outcome())
    let reply = try #require(try await World.messages(in: book.store).last)
    #expect(reply.appliedProposal == applied && reply.cardProposal == nil && reply.applyNote == nil)
    #expect(try await World.steps(of: direct.reply, in: book.store) == [])

    let other = try await World.book()
    let splitTurn = try await begun(World.message, engine: try await World.engine(other.store, provider: ScriptedModelProvider()), book: other)
    let both = try settled("Done.", changeSet: "[\(World.maraThief),\(World.removeRise)]")
    let staging = try await other.store.stageTurn(stagingRequest(splitTurn, both))
    let (appliedSplit, card) = (try #require(staging.appliedProposal), try #require(staging.cardProposal))
    #expect(try await World.steps(of: splitTurn.reply, in: other.store) == [.applied(proposal: appliedSplit, cardsFollow: true), .cards(proposal: card)])
  }

  // A card step that left every op out holds no card, and nothing is missing
  @Test func shouldNotSayCardsAreMissingWhenTheirStepLeftEveryOpOut() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let basis = try await begun(World.message, engine: engine, book: book)
    let answer = try settled("Done — I noted it.", changeSet: "[\(World.maraThief)]")
    try await book.run { try ChatTurnRecords.settle(basis.turn, answer, in: $0.database) }
    let applied = try #require(try await book.store.stageTurn(stagingRequest(basis, answer)).appliedProposal)
    try await book.run { transaction in
      try TurnStagingMarks.record(.applied(proposal: applied, cardsFollow: true), reply: basis.reply, session: basis.session, in: transaction.database)
      try TurnStagingMarks.record(.cards(proposal: nil), reply: basis.reply, session: basis.session, in: transaction.database)
    }
    let handles = try await World.engine(book.store, provider: ScriptedModelProvider()).resumeInterruptedTurns()
    _ = try World.reply(of: await handles[0].outcome())
    let reply = try #require(try await World.messages(in: book.store).last)
    #expect(reply.appliedProposal == applied && reply.cardProposal == nil && reply.applyNote == nil)
  }

  // A store of begun calls that lands once the turn is no longer pending here leaves nothing for a later run to claim
  @Test func shouldStoreNoCallOfATurnThatIsNoLongerPending() async throws {
    let book = try await World.book()
    let basis = try await begun(World.message, engine: try await World.engine(book.store, provider: ScriptedModelProvider()), book: book)
    let (kept, late) = (UUID(), UUID())
    try await book.run { try ChatTurnRecords.began([kept], turn: basis.turn, session: basis.session, in: $0.database) }
    try await book.run { try LocalTurnStore.end(basis.turn, as: .cancelled, at: Date(), in: $0.database) }
    try await book.run { try ChatTurnRecords.began([late], turn: basis.turn, session: basis.session, in: $0.database) }
    #expect(try await World.record(basis.turn, in: book.store)?.calls == [kept])
  }

  // A retry that asks again from the message starts its calls afresh: the failed run's call is not the retried run's
  @Test func shouldStartTheCallsAfreshWhenARetryAsksAgain() async throws {
    let book = try await World.book()
    let broken: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thin"#), .failure(.authentication)]
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [broken, stalled]))
    let first = try await engine.send(World.message, session: World.session, novel: book.novel)
    guard case .failed = await first.outcome() else {
      Issue.record("the first run did not fail")
      return
    }
    let failed = try #require(try await World.record(first.turn, in: book.store)?.calls)
    #expect(failed.count == 1)

    let retried = try await engine.retry(turn: first.turn)
    for await event in retried.events {
      if case .delta = event { break }
    }
    engine.interrupt(turn: retried.turn)
    #expect(await retried.outcome() == .interrupted)
    let calls = try #require(try await World.record(first.turn, in: book.store)?.calls)
    #expect(calls.count == 1 && calls != failed)
  }

  @Test func shouldFailAnInterruptedTurnItCannotResumeAtLaunch() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let basis = try await begun("Hello.", engine: engine, book: book)
    try await book.run { try ChatTurnRecords.forget(basis.turn, in: $0.database) }
    #expect(try await engine.resumeInterruptedTurns().isEmpty)
    let local = try #require(try await World.localTurn(basis.turn, in: book.store))
    #expect(local.state == .failed && local.failure == LocalTurnStore.interrupted)
  }
}
