import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

private let negated = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
private let revised = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She travels light to the tower."}"#

private func negatedAnswer() -> [ScriptedModelProvider.Step] {
  World.reply(("reply", World.text("Dropped the dagger.")), ("changeSet", "[\(negated)]"))
}

private func revisedAnswer() -> [ScriptedModelProvider.Step] {
  World.reply(("reply", World.text("Rewrote it.")), ("changeSet", "[\(revised)]"))
}

/// The history as it was, then the author's message sent again and its one reply.
private func expectAnsweredOnce(_ store: VaultStore, after history: [ChatMessageRecord]) async throws {
  let messages = try await World.messages(in: store)
  #expect(messages.prefix(history.count).map(\.id) == history.map(\.id))
  let added = messages.dropFirst(history.count)
  #expect(added.map(\.content) == ["What next?", "Noted."])
  #expect(added.last?.answers == added.first?.id)
}

/// A process killed while a turn was asking the model: what the killed run was answered with before its call froze, what its resume is answered with (the
/// fewest calls the saved state allows), and what the same conversation answers when nothing stops it.
struct AskingCrash: Sendable, CustomTestStringConvertible {
  let name: String
  var message = EngineWorld.message
  let killed: [KillableProvider.Call]
  let resumed: [[ScriptedModelProvider.Step]]
  let uncrashed: [[ScriptedModelProvider.Step]]
  /// The killed run's frames reach the file before the crash.
  var flushes = false
  var rounds = 0
  var dagger = false

  var testDescription: String { name }

  static let cases: [AskingCrash] =
    [
      AskingCrash(name: "after the message is saved, before the first call answers", killed: [.freeze([])], resumed: [Crash.split()], uncrashed: [Crash.split()]),
      AskingCrash(name: "mid-stream, frames not yet written", killed: [.freeze(Crash.shown)], resumed: [Crash.split()], uncrashed: [Crash.split()]),
      AskingCrash(name: "mid-stream, frames written", killed: [.freeze(Crash.shown)], resumed: [Crash.split()], uncrashed: [Crash.split()], flushes: true),
    ]
    + (1...3).map { round in
      AskingCrash(
        name: "after lookup round \(round) was saved", killed: Array(repeating: .answer(Crash.lookup()), count: round) + [.freeze(Crash.shown)],
        resumed: Array(repeating: Crash.lookup(), count: 3 - round) + [Crash.split()], uncrashed: Array(repeating: Crash.lookup(), count: 3) + [Crash.split()],
        rounds: round)
    }
    + [
      AskingCrash(
        name: "during the negation fix round", message: "Take her dagger away.", killed: [.answer(negatedAnswer()), .freeze([])],
        resumed: [negatedAnswer(), revisedAnswer()], uncrashed: [negatedAnswer(), revisedAnswer()], dagger: true)
    ]

  func prepare(_ book: ChapterBook) async throws {
    guard dagger else { return }
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
  }
}

// Orchestrator decision 6 at every boundary of the asking half: the process ends with a model call in flight, the next launch resumes the turn from its
// last saved round, and a second crash after the resumed run settled its answer leaves it to a third launch that asks nothing
@Suite("Chat turns killed while asking", .serialized, TestTimeLimit.standard)
struct ChatTurnAskingCrashTests {
  @Test(arguments: AskingCrash.cases)
  func shouldResumeAKilledTurnFromItsLastSavedRoundWithOneReplyAndNothingAppliedTwice(_ crash: AskingCrash) async throws {
    let expected = try await Crash.uncrashed(crash.uncrashed, message: crash.message) { try await crash.prepare($0) }
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    try await crash.prepare(killed)
    let provider = KillableProvider(turns: crash.killed)
    let engine = try await Crash.engine(killed.store, provider: provider, flush: crash.flushes ? .milliseconds(50) : .seconds(3_600))
    let handle = try await engine.send(crash.message, session: World.session, novel: killed.novel)
    try await provider.waitFrozen()
    if crash.flushes {
      let store = killed.store
      try await World.eventually("the shown text reaches the file") { Crash.hasDelta(try await store.localTurnFrames(handle.turn)) }
    }

    let launched = try vault.open()
    let stored = try await launched.store.localTurnFrames(handle.turn)
    #expect(Crash.sequences(stored) == Crash.contiguous(stored.count))
    if crash.rounds == 0 { #expect(Crash.hasDelta(stored) == crash.flushes) }
    if crash.flushes { #expect(stored.first?.decoded == .user(message: handle.userMessage)) }
    let local = try #require(try await launched.store.localTurn(handle.turn))
    #expect(local.state == .pending && local.savedRounds == crash.rounds)
    let script = ScriptedModelProvider(calls: crash.resumed)
    let resumer = try await Crash.engine(launched.store, provider: script, faults: World.faults(.crash, at: .appending))
    #expect(try await resumer.activity(session: World.session) == .interrupted(local))
    var replayed = [TurnStreamEvent]()
    for await event in try await resumer.observe(turn: handle.turn) { replayed.append(event) }
    #expect(replayed == stored.compactMap(\.decoded))

    let resumed = try await resumer.resumeInterruptedTurns()
    #expect(resumed.map(\.turn) == [handle.turn])
    #expect(await resumed.first?.outcome() == .interrupted)
    #expect(script.requests.count == crash.resumed.count && script.remainingCalls == 0)
    if crash.rounds > 0 {
      let results = script.requests[0].messages.filter { $0.text.hasPrefix("Lookup results:") }
      #expect(results.count == crash.rounds)
      #expect((crash.rounds == 3) == (results.last?.text.contains("Lookup budget exhausted") == true))
    }
    let written = try await launched.store.localTurnFrames(handle.turn)
    #expect(Crash.sequences(written) == Crash.contiguous(written.count) && written.count > stored.count)
    #expect(Array(written.prefix(stored.count)) == stored && written.dropFirst(stored.count).first?.decoded == .reset)
    #expect(try await World.record(handle.turn, in: launched.store)?.staged != nil)

    let relaunched = try vault.open()
    let idle = ScriptedModelProvider()
    let finisher = try await Crash.engine(relaunched.store, provider: idle)
    let finishing = try await finisher.resumeInterruptedTurns()
    #expect(finishing.map(\.turn) == [handle.turn])
    let events = await World.events(try #require(finishing.first))
    #expect(try World.reply(of: await finishing[0].outcome()) == handle.turn)
    #expect(events.first == .reset && events.last == .done(reply: handle.turn))
    #expect(idle.requests.isEmpty)
    #expect(provider.turnRequests.count == crash.killed.count)

    #expect(try await Crash.footprint(in: relaunched.store) == expected)
    try await Crash.expectOneReplyPerMessage(relaunched.store)
    try await Crash.expectSettled(finisher, relaunched.store)
    var after = [TurnStreamEvent]()
    for await event in try await finisher.observe(turn: handle.turn) { after.append(event) }
    #expect(after.isEmpty)
  }

  // Killed while the fold before routing was in flight: nothing of the turn was saved, so nothing resumes and the author's next send folds once
  @Test func shouldResumeNothingWhenKilledBeforeTheMessageWasSaved() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let history = try CompactionWorld.turns(14)
    try await killed.run { transaction in for message in history { _ = try message.append(in: &transaction) } }
    let provider = KillableProvider(turns: [.freeze([])])
    let engine = try await Crash.engine(killed.store, provider: provider)
    _ = Task { try await engine.send("What next?", session: World.session, novel: killed.novel) }
    try await provider.waitFrozen()

    let launched = try vault.open()
    let script = ScriptedModelProvider(calls: [CompactionWorld.reply("They planned the heist."), World.reply(("reply", World.text("Noted.")))])
    let relaunched = try await Crash.engine(launched.store, provider: script)
    #expect(try await relaunched.resumeInterruptedTurns().isEmpty)
    #expect(try await launched.store.pendingLocalTurns().isEmpty)
    #expect(try await World.messages(in: launched.store).count == 14)
    #expect(try await CompactionWorld.summaries(in: launched.store).isEmpty)
    #expect(try await relaunched.activity(session: World.session) == .idle)

    _ = try World.reply(of: await relaunched.send("What next?", session: World.session, novel: launched.novel).outcome())
    #expect(script.requests.count == 2)
    #expect(try await CompactionWorld.summaries(in: launched.store).count == 1)
    try await expectAnsweredOnce(launched.store, after: history)
    try await Crash.expectSettled(relaunched, launched.store)
    #expect(provider.turnRequests.count == 1)
  }

  // Killed after the fold committed its summary and before the turn routed: the summary stands, nothing resumes, and the next send does not fold again
  @Test func shouldKeepTheFoldAndNotFoldAgainWhenKilledAfterCompaction() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let history = try CompactionWorld.turns(14)
    try await killed.run { transaction in for message in history { _ = try message.append(in: &transaction) } }
    let fold = try await CompactionWorld.compact(store: killed.store, provider: ScriptedModelProvider(calls: [CompactionWorld.reply("They planned the heist.")]))
    guard case .folded = fold.outcome else {
      Issue.record("the window did not fold: \(fold.outcome)")
      return
    }

    let launched = try vault.open()
    let script = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Noted.")))])
    let relaunched = try await Crash.engine(launched.store, provider: script)
    #expect(try await relaunched.resumeInterruptedTurns().isEmpty)
    #expect(try await CompactionWorld.summaries(in: launched.store).count == 1)
    _ = try World.reply(of: await relaunched.send("What next?", session: World.session, novel: launched.novel).outcome())
    #expect(script.requests.count == 1)
    #expect(script.requests[0].messages.first?.text == "Conversation so far (compacted summary):\nThey planned the heist.")
    #expect(try await CompactionWorld.summaries(in: launched.store).count == 1)
    try await expectAnsweredOnce(launched.store, after: history)
    try await Crash.expectSettled(relaunched, launched.store)
  }

  // Two chats killed mid-turn at once: each resumes on its own and gets one reply
  @Test func shouldResumeEveryChatKilledMidTurn() async throws {
    let other = StagingWorld.otherSession
    let vault = try await CrashVault.make(sessions: [World.session, other])
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.freeze(Crash.shown), .freeze(Crash.shown)])
    let engine = try await Crash.engine(killed.store, provider: provider)
    let first = try await engine.send("Plan the heist.", session: World.session, novel: killed.novel)
    let second = try await engine.send("Plan the escape.", session: other, novel: killed.novel)
    try await provider.waitFrozen(2)

    let launched = try vault.open()
    let script = ScriptedModelProvider(calls: [World.reply(("reply", World.text("Here."))), World.reply(("reply", World.text("Here too.")))])
    let relaunched = try await Crash.engine(launched.store, provider: script)
    let handles = try await relaunched.resumeInterruptedTurns()
    #expect(Set(handles.map(\.turn)) == [first.turn, second.turn])
    for handle in handles { _ = try World.reply(of: await handle.outcome()) }
    #expect(script.requests.count == 2)
    for session in [World.session, other] {
      try await Crash.expectOneReplyPerMessage(launched.store, session: session)
      try await Crash.expectSettled(relaunched, launched.store, session: session)
    }
  }

  // F27 1d, orchestrator decision 9: the call a crash cut off stays begun in the ledger, its cost pending, and the resumed turn's reply carries its id
  @Test func shouldCarryTheLedgerIdOfTheCallACrashCutOffOnTheResumedReply() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.freeze(Crash.shown)])
    let engine = try await Crash.engine(killed.store, provider: provider)
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    try await provider.waitFrozen()
    try await World.eventually("the call's ledger id was stored with the turn") { try await World.record(handle.turn, in: killed.store)?.calls.count == 1 }

    let launched = try vault.open()
    let cut = try #require(try await World.record(handle.turn, in: launched.store)?.calls.first)
    let relaunched = try await Crash.engine(launched.store, provider: ScriptedModelProvider(calls: [Crash.split()]))
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    _ = try World.reply(of: await resumed.outcome())

    let reply = try #require(try await World.messages(in: launched.store).last)
    let ledger = try await launched.store.read { try Ledger.entries(in: $0) }.filter { $0.parent == nil }
    #expect(ledger.map(\.id) == reply.modelCalls)
    #expect(reply.modelCalls?.count == 2 && reply.modelCalls?.first == cut)
    #expect(ledger.first { $0.id == cut }?.outcome == .started)
    try await Crash.expectSettled(relaunched, launched.store)
  }
}
