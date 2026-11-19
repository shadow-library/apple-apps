import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private let stalled: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it"#), .delay(.seconds(120))]

private func split() -> [ScriptedModelProvider.Step] {
  World.reply(("reply", World.text("Done — I noted it.")), ("changeSet", "[\(World.maraThief),\(World.removeRise)]"))
}

private func expectStagedOnce(_ book: ChapterBook, reply: UUID) async throws {
  let proposals = try await World.proposals(of: reply, in: book.store)
  #expect(proposals.count == 2)
  #expect(try await World.proposalCount(in: book.store) == 2)
  #expect(proposals.count(where: { $0.decision == .known(.applied) }) == 1)
}

private func failure(of outcome: ChatTurnOutcome) -> TurnFailure? {
  guard case .failed(let failure) = outcome else { return nil }
  return failure
}

// Every step boundary of the finishing half of a turn, with the answer saved by the engine itself
@Suite("Chat turn faults", TestTimeLimit.standard)
struct ChatTurnFaultTests {
  @Test func shouldNeverStageTwiceAfterACrashOnceTheEngineSavedItsAnswer() async throws {
    for point in [ChatTurnEngine.Faults.Point.settled, .staged, .appending] {
      let book = try await World.book()
      let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [split()]), faults: World.faults(.crash, at: point))
      let handle = try await first.send(World.message, session: World.session, novel: book.novel)
      #expect(await handle.outcome() == .interrupted, "\(point)")
      let saved = try #require(try await World.record(handle.turn, in: book.store), "\(point)")
      #expect(saved.settled?.reply == "Done — I noted it.", "\(point)")
      #expect((saved.staged != nil) == (point == .appending), "\(point)")

      let provider = ScriptedModelProvider()
      let handles = try await World.engine(book.store, provider: provider).resumeInterruptedTurns()
      let reply = try World.reply(of: await handles[0].outcome())
      #expect(provider.requests.isEmpty, "\(point)")
      try await expectStagedOnce(book, reply: reply)
      let record = try #require(try await World.messages(in: book.store).last)
      #expect(record.appliedProposal != nil && record.cardProposal != nil, "\(point)")
      #expect(try await book.entity("mara")?.status == "thief")
    }
  }

  // B1: what staging committed is read from the steps its transactions recorded, so a fault on the derived proposal rows changes nothing
  @Test func shouldRecoverFromTheRecordedStepsWhateverTheProposalProjectionHolds() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [split()]), faults: World.faults(.crash, at: .staged))
    let handle = try await first.send(World.message, session: World.session, novel: book.novel)
    #expect(await handle.outcome() == .interrupted)
    _ = try await book.store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO nf_derived_fault (derivation, key, version, message) VALUES (?, ?, 1, 'broken')",
        arguments: [ProposalState.databaseTableName, ProjectionFaults.key(NovelForgeKey.proposal(UUID()))])
      try transaction.database.execute(sql: "DELETE FROM \(ProposalState.databaseTableName)")
    }
    let handles = try await World.engine(book.store, provider: ScriptedModelProvider()).resumeInterruptedTurns()
    try await expectStagedOnce(book, reply: try World.reply(of: await handles[0].outcome()))
  }

  @Test func shouldFailRatherThanStageAgainWhenTheRecordedStepsCannotBeRead() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [split()]), faults: World.faults(.crash, at: .staged))
    let handle = try await first.send(World.message, session: World.session, novel: book.novel)
    #expect(await handle.outcome() == .interrupted)
    _ = try await book.store.write { transaction in
      try transaction.database.execute(sql: "UPDATE \(TurnStagingMarks.table) SET proposal = x'00' WHERE step = 'applied'")
    }
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider())
    let handles = try await engine.resumeInterruptedTurns()
    #expect(failure(of: await handles[0].outcome())?.code == recoveryUnavailableCode)
    #expect(try await World.proposalCount(in: book.store) == 2)
    #expect(try await World.localTurn(handle.turn, in: book.store)?.state == .failed)
    #expect(try await World.messages(in: book.store).count == 1)

    let retried = try await engine.retry(turn: handle.turn)
    #expect(failure(of: await retried.outcome())?.code == recoveryUnavailableCode)
    #expect(try await World.proposalCount(in: book.store) == 2)
  }

  // turn-proposals.ts:19: the author's words applied but the reply could not be written; a retry links the reply to what was staged, never staging again
  @Test func shouldReportAnUnlinkedTurnAndLinkItsReplyOnRetry() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [split()]), faults: World.faults(.failure, at: .appending))
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    let failed = try #require(failure(of: await handle.outcome()))
    #expect(failed == TurnFailure(code: unlinkedFailureCode, message: unlinkedNote))
    let staged = try #require(try await World.record(handle.turn, in: book.store)?.staged)
    #expect(staged.appliedProposal != nil && staged.cardProposal != nil)
    let frames = try await book.store.localTurnFrames(handle.turn)
    #expect(frames.map(\.sequence) == Array(1...frames.count))
    #expect(frames.contains { $0.event == .delta } && frames.last?.decoded == .error(failed))

    let reply = try World.reply(of: await engine.retry(turn: handle.turn).outcome())
    let record = try #require(try await World.messages(in: book.store).last)
    #expect(record.id == reply && record.appliedProposal == staged.appliedProposal && record.cardProposal == staged.cardProposal)
    try await expectStagedOnce(book, reply: reply)
  }

  // The saved staged result keeps what staging said, so a retry's reply says it too
  @Test func shouldRestoreTheStagedNotesWhenTheReplyIsWrittenOnRetry() async throws {
    let book = try await World.book()
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
    let negated = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
    let provider = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Dropped the dagger.")), ("changeSet", "[\(negated)]")), [.failure(.authentication)]])
    let engine = try await World.engine(book.store, provider: provider, faults: World.faults(.failure, at: .appending))
    let handle = try await engine.send("Take her dagger away.", session: World.session, novel: novel)
    #expect(failure(of: await handle.outcome()) != nil)
    let staged = try #require(try await World.record(handle.turn, in: book.store)?.staged)
    #expect(staged.held == TurnHoldReason.warnings.rawValue && staged.applyNote == heldForReviewNote && staged.cardProposal != nil)

    _ = try World.reply(of: await engine.retry(turn: handle.turn).outcome())
    let record = try #require(try await World.messages(in: book.store).last)
    #expect(record.held == staged.held && record.applyNote == staged.applyNote && record.cardProposal == staged.cardProposal)
    #expect(try await World.proposalCount(in: book.store) == 1)
  }

  @Test func shouldAppendTheReplyWhenOnlySavingTheStagedResultFailed() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [split()]), faults: World.faults(.failure, at: .staged))
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    let reply = try World.reply(of: await handle.outcome())
    try await expectStagedOnce(book, reply: reply)
    #expect(try await World.record(handle.turn, in: book.store) == nil)
  }

  // model-router.service.ts:822-825 and the F22a relay: a reply that breaks off after it showed text voids what it showed
  @Test func shouldVoidShownTextWhenTheReplyBreaksOffMidStream() async throws {
    let book = try await World.book()
    let provider = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Partial text here."#), .failure(.midStream(code: "x", message: "boom"))]
    ])
    let engine = try await World.engine(book.store, provider: provider)
    let handle = try await engine.send("Go.", session: World.session, novel: book.novel)
    let failed = try #require(failure(of: await handle.outcome()))
    #expect(failed.code == "model.mid_stream")
    let events = await World.events(handle)
    let delta = try #require(events.firstIndex { if case .delta = $0 { true } else { false } })
    let reset = try #require(events.lastIndex(of: .reset))
    #expect(delta < reset && events.last == .error(failed))
  }

  // chat.service.ts:373
  @Test func shouldDropTheQuestionOfAnAnswerThatStillAsksForLookupsAfterTheCap() async throws {
    let book = try await World.book()
    let lookup = World.reply(("reply", World.text("Checking.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#))
    let question = #"{"question":"Which way?","answers":[{"title":"North"},{"title":"South"}]}"#
    let provider = ScriptedModelProvider(calls: [
      lookup, lookup, lookup,
      World.reply(("reply", World.text("Final.")), ("lookups", #"[{"tool":"get_entity","args":{"entityKey":"mara"}}]"#), ("question", question)),
    ])
    let engine = try await World.engine(book.store, provider: provider)
    let reply = try World.reply(of: await engine.send("Who?", session: World.session, novel: book.novel).outcome())
    let record = try #require(try await World.messages(in: book.store).last)
    #expect(record.id == reply && record.content == "Final." && record.question == nil && record.cardProposal == nil)
  }

  // chat-lookup.service.ts:68-79: a tool's per-turn budget holds across a resumed turn
  @Test func shouldKeepEachToolsBudgetAcrossAResume() async throws {
    let book = try await World.book()
    let twice = World.reply(
      ("reply", World.text("Reading.")), ("lookups", #"[{"tool":"get_draft","args":{"chapter":1}},{"tool":"get_draft","args":{"chapter":2}}]"#))
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [twice, stalled]))
    let handle = try await first.send("Read them.", session: World.session, novel: book.novel)
    let store = book.store
    try await World.eventually("the lookup round is saved") { try await store.localTurn(handle.turn)?.savedRounds == 1 }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)

    let again = World.reply(("reply", World.text("Once more.")), ("lookups", #"[{"tool":"get_draft","args":{"chapter":3}}]"#))
    let provider = ScriptedModelProvider(calls: [again, World.reply(("reply", World.text("Done.")))])
    let handles = try await World.engine(book.store, provider: provider).resumeInterruptedTurns()
    _ = try World.reply(of: await handles[0].outcome())
    #expect(provider.requests.count == 2)
    #expect(provider.requests[1].messages.last?.text.contains("error: tool 'get_draft' has exceeded its call budget for this turn") == true)
  }

  // N3: what a failed write took is written by the next one, ahead of what came after, so no sequence is skipped
  @Test func shouldGiveBackTheFramesAndRequestOfAFailedWrite() throws {
    let stream = ChatTurnStream(after: 4, sources: [], now: { 0 })
    let message = UUID()
    stream.emit(.user(message: message))
    let request = ModelRequest(model: "m", system: [], messages: [.user("hi")], maxOutputTokens: 1)
    stream.sent(StructuredAttempt(number: 1, mode: .native, purpose: .answer, request: request))
    let failed = stream.take()
    stream.requeue(failed)
    stream.emit(.delta("Hello"))
    let next = stream.take()
    #expect(next.frames.map(\.sequence) == [5, 6])
    #expect(next.frames.first?.decoded == .user(message: message) && next.attempt?.request == request)
    #expect(stream.take().isEmpty)
  }

  // N4: a view that reopens follows the turn again, every observer from its first stored frame
  @Test func shouldReplayATurnsEventsToEveryObserverAndFollowItLive() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await engine.send("Go.", session: World.session, novel: book.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    let (one, two) = (try await engine.observe(turn: handle.turn), try await engine.observe(turn: handle.turn))
    engine.cancel(turn: handle.turn)
    #expect(await handle.outcome() == .cancelled)
    var seen = [[TurnStreamEvent]]()
    for stream in [one, two] {
      var events = [TurnStreamEvent]()
      for await event in stream { events.append(event) }
      seen.append(events)
    }
    #expect(seen[0] == seen[1])
    #expect(seen[0].first == .user(message: handle.userMessage) && seen[0].contains { if case .delta = $0 { true } else { false } })

    var stored = [TurnStreamEvent]()
    for await event in try await engine.observe(turn: handle.turn) { stored.append(event) }
    #expect(stored.first == .user(message: handle.userMessage) && stored.count >= 2)
  }

  @Test func shouldFailAPendingTurnWithNoRecordInsteadOfLeavingItPending() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Go.", session: World.session, novel: book.novel)
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)
    try await book.run { try ChatTurnRecords.forget(handle.turn, in: $0.database) }
    await #expect { _ = try await first.resume(turn: handle.turn) } throws: { ($0 as? ChatTurnError)?.code == ChatTurnError.turnNotRetryable.code }
    let local = try #require(try await World.localTurn(handle.turn, in: book.store))
    #expect(local.state == .failed && local.failure == LocalTurnStore.interrupted)
  }

  @Test func shouldNotResumeOrRetryATurnWhoseChatWasArchived() async throws {
    let book = try await World.book()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled, [.failure(.authentication)]]))
    let pending = try await engine.send("Go.", session: World.session, novel: book.novel)
    engine.interrupt(turn: pending.turn)
    #expect(await pending.outcome() == .interrupted)
    var edit = ChatSessionEdit()
    edit.setStatus(.archived)
    let archived = edit
    try await book.run { _ = try ChatSessionRecord.edit(id: World.session, archived, in: &$0) }

    await #expect { _ = try await engine.resume(turn: pending.turn) } throws: { ($0 as? ChatTurnError)?.code == "CHT_002" }
    #expect(try await World.localTurn(pending.turn, in: book.store)?.failure?.code == "CHT_002")
    await #expect { _ = try await engine.retry(turn: pending.turn) } throws: { ($0 as? ChatTurnError)?.code == "CHT_002" }
  }

  @Test func shouldNotNameTheSessionWhenAnsweringAnOpeningMessageSentElsewhere() async throws {
    let book = try await World.book()
    let opening = try ChatWorld.message(content: "Plan the heist.")
    try await book.run { _ = try opening.append(in: &$0) }
    let upkeep = RecordedUpkeep()
    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [World.reply(("reply", World.text("Here.")))]), upkeep: upkeep)
    _ = try World.reply(of: await engine.answer(message: opening.id, session: World.session, novel: book.novel).outcome())
    #expect(upkeep.named.isEmpty)
  }
}
