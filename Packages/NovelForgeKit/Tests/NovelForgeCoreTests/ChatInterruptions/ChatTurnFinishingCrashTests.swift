import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

/// Runs a turn on the vault until it crashes at `point`, answered with the split change set; nothing it would write after that point is written.
private func killed(at point: ChatTurnEngine.Faults.Point, vault: CrashVault) async throws -> ChatTurnHandle {
  let book = try vault.open()
  let engine = try await Crash.engine(book.store, provider: ScriptedModelProvider(calls: [Crash.split()]), faults: World.faults(.crash, at: point))
  let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
  #expect(await handle.outcome() == .interrupted)
  return handle
}

/// The first staging transaction of `turn`'s saved answer, as `TurnStagingFlow.stage` runs it, and none after it: the state a crash between the applied side
/// and its cards leaves.
private func stagedAppliedSideOnly(_ turn: UUID, in store: VaultStore) async throws -> UUID {
  let record = try #require(try await World.record(turn, in: store))
  let (basis, answer) = (record.basis, try #require(record.settled))
  let request = TurnStagingRequest(
    novel: basis.novel, session: basis.session, reply: basis.reply, replyText: answer.reply, changeSet: answer.changeSet, authorMessage: basis.authorWords,
    mode: basis.sessionMode, justDiscussing: basis.justDiscussing, organise: basis.organise, contexts: basis.contexts, warnings: answer.warnings,
    run: basis.turn.uuidString.lowercased(), now: Date())
  let ops = try parseOptionalChangeSet(answer.changeSet.map { .array($0.map(OrderedJSON.object)) }, allowedOps: hubAllowedOps)
  let plan = try await store.write { transaction in try TurnStagingPlan.make(request, ops: ops, in: transaction) }
  guard case .split(let turn) = plan.route, !turn.split.direct.isEmpty, !turn.split.cards.isEmpty else { throw StagingCrashError.notSplit }
  let direct = await TurnStoreSteps(store: store, request: request).applyDirect(
    turn.split.direct, sources: turn.split.sources, entityMaterialization: false, cardsFollow: true, notes: TurnStagingNotes(applyNote: cardsUnsavedNote))
  guard case .applied(let proposal, _) = direct else { throw StagingCrashError.notApplied(direct) }
  return proposal
}

private enum StagingCrashError: Error {
  case notSplit
  case notApplied(TurnDirectOutcome)
}

/// A turn whose staging leaves notes for its reply: a hold and its note, or why a rewrite was left out.
struct NotedStaging: Sendable, CustomTestStringConvertible {
  let name: String
  let message: String
  let ops: [String]
  let held: TurnHoldReason?
  let applyNote: String?
  let notesReply: Bool
  var choices = ChatTurnChoices()
  var dagger = false

  var testDescription: String { name }

  static let cases = [
    NotedStaging(
      name: "held for review", message: "Take her dagger away.",
      ops: [#"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#], held: .warnings,
      applyNote: heldForReviewNote, notesReply: false, dagger: true),
    NotedStaging(
      name: "a rewrite left out", message: EngineWorld.message, ops: [StagingText.rewrite("words that are nowhere in the chapter", "new words"), EngineWorld.removeRise],
      held: nil, applyNote: nil, notesReply: true, choices: ChatTurnChoices(proseEdits: true)),
  ]

  func prepare(_ book: ChapterBook) async throws {
    guard dagger else { return }
    let novel = book.novel
    try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
  }
}

// The finishing half of a turn, each boundary killed on a vault in a file and resumed by a relaunched app: the answer is never asked for again and nothing
// is staged or applied twice, so the vault ends as an uninterrupted turn leaves it
@Suite("Chat turns killed while finishing", .serialized, TestTimeLimit.standard)
struct ChatTurnFinishingCrashTests {
  @Test(arguments: [ChatTurnEngine.Faults.Point.settled, .staged, .appending])
  func shouldFinishAKilledTurnFromWhatItSavedAsIfNeverStopped(_ point: ChatTurnEngine.Faults.Point) async throws {
    let expected = try await Crash.uncrashed([Crash.split()])
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let handle = try await killed(at: point, vault: vault)

    let launched = try vault.open()
    let stored = try await launched.store.localTurnFrames(handle.turn)
    #expect(Crash.sequences(stored) == Crash.contiguous(stored.count) && Crash.hasDelta(stored))
    let local = try #require(try await launched.store.localTurn(handle.turn))
    let idle = ScriptedModelProvider()
    let engine = try await Crash.engine(launched.store, provider: idle)
    #expect(try await engine.activity(session: World.session) == .interrupted(local))
    var replayed = [TurnStreamEvent]()
    for await event in try await engine.observe(turn: handle.turn) { replayed.append(event) }
    #expect(replayed == stored.compactMap(\.decoded))

    let handles = try await engine.resumeInterruptedTurns()
    #expect(handles.map(\.turn) == [handle.turn])
    let events = await World.events(try #require(handles.first))
    #expect(try World.reply(of: await handles[0].outcome()) == handle.turn)
    #expect(events == [.reset, .done(reply: handle.turn)])
    #expect(idle.requests.isEmpty)
    #expect(try await Crash.footprint(in: launched.store) == expected)
    try await Crash.expectOneReplyPerMessage(launched.store)
    try await Crash.expectSettled(engine, launched.store)
  }

  // Killed after staging, then killed again where the resumed run appends its reply: the third launch still stages nothing and asks nothing
  @Test func shouldFinishATurnKilledTwiceWithoutStagingAgain() async throws {
    let expected = try await Crash.uncrashed([Crash.split()])
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let handle = try await killed(at: .staged, vault: vault)

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let again = try await Crash.engine(launched.store, provider: idle, faults: World.faults(.crash, at: .appending))
    let resumed = try await again.resumeInterruptedTurns()
    #expect(await resumed.first?.outcome() == .interrupted)
    let steps = try await World.steps(of: handle.turn, in: launched.store)
    guard case .applied(let applied, true)? = steps?.first, case .cards(let card?)? = steps?.last else {
      Issue.record("the staging steps did not survive the second crash: \(String(describing: steps))")
      return
    }

    let relaunched = try vault.open()
    let engine = try await Crash.engine(relaunched.store, provider: idle)
    let finishing = try #require(try await engine.resumeInterruptedTurns().first)
    let reply = try World.reply(of: await finishing.outcome())
    #expect(idle.requests.isEmpty)
    let record = try #require(try await World.messages(in: relaunched.store).last)
    #expect(record.id == reply && record.appliedProposal == applied && record.cardProposal == card)
    #expect(try await Crash.footprint(in: relaunched.store) == expected)
    try await Crash.expectSettled(engine, relaunched.store)
  }

  // Killed inside staging, after the applied side committed and before its cards: the author's words stand applied once, and the reply says the suggestions
  // were not saved (turn-proposals.ts:160), since the recovery reads only the steps that committed and never stages the change set again
  @Test func shouldApplyOnceAndSayTheCardsAreMissingWhenKilledBetweenTheStagingTransactions() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let handle = try await killed(at: .settled, vault: vault)
    let killedBook = try vault.open()
    let applied = try await stagedAppliedSideOnly(handle.turn, in: killedBook.store)
    #expect(try await World.steps(of: handle.turn, in: killedBook.store) == [.applied(proposal: applied, cardsFollow: true)])
    let hashes = try await Crash.footprint(in: killedBook.store).hashes

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let engine = try await Crash.engine(launched.store, provider: idle)
    let finishing = try #require(try await engine.resumeInterruptedTurns().first)
    let reply = try World.reply(of: await finishing.outcome())
    #expect(idle.requests.isEmpty)
    let record = try #require(try await World.messages(in: launched.store).last)
    #expect(record.id == reply && record.appliedProposal == applied && record.cardProposal == nil && record.applyNote == cardsUnsavedNote)
    let footprint = try await Crash.footprint(in: launched.store)
    #expect(footprint.proposals == ["applied automatic=true ops=entity.upsert"])
    #expect(footprint.hashes == hashes)
    #expect(try await launched.entity("mara")?.status == "thief")
    try await Crash.expectOneReplyPerMessage(launched.store)
    try await Crash.expectSettled(engine, launched.store)
  }

  // Killed after the staged result was saved, with a staging that held the change set for review: the resumed reply keeps the hold and its note
  @Test func shouldKeepTheHoldAndItsNoteWhenKilledBeforeTheReplyWasAppended() async throws {
    let negated = #"{"op":"entity.upsert","entityKey":"mara","type":"character","name":"Mara","motivation":"She carries no dagger to the tower."}"#
    let script = [World.reply(("reply", World.text("Dropped the dagger.")), ("changeSet", "[\(negated)]")), [ScriptedModelProvider.Step.failure(.authentication)]]
    let dagger: @Sendable (ChapterBook) async throws -> Void = { book in
      let novel = book.novel
      try await book.run { try Entities.edit(novel: novel, entity: "mara", EntityDetails(motivation: "She carries a dagger to the tower."), in: &$0) }
    }
    let message = "Take her dagger away."
    let expected = try await Crash.uncrashed(script, message: message, prepare: dagger)
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let book = try vault.open()
    try await dagger(book)
    let engine = try await Crash.engine(book.store, provider: ScriptedModelProvider(calls: script), faults: World.faults(.crash, at: .appending))
    let handle = try await engine.send(message, session: World.session, novel: book.novel)
    #expect(await handle.outcome() == .interrupted)
    let staged = try #require(try await World.record(handle.turn, in: book.store)?.staged)
    #expect(staged.held == TurnHoldReason.warnings.rawValue && staged.applyNote == heldForReviewNote && staged.cardProposal != nil)

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let relaunched = try await Crash.engine(launched.store, provider: idle)
    let finishing = try #require(try await relaunched.resumeInterruptedTurns().first)
    _ = try World.reply(of: await finishing.outcome())
    #expect(idle.requests.isEmpty)
    let reply = try #require(try await World.messages(in: launched.store).last)
    #expect(reply.held == staged.held && reply.applyNote == heldForReviewNote && reply.cardProposal == staged.cardProposal && reply.appliedProposal == nil)
    #expect(try await Crash.footprint(in: launched.store) == expected)
    try await Crash.expectSettled(relaunched, launched.store)
  }

  // Killed after staging committed and before its result was saved: the reply takes the notes the last staging step recorded, so it holds and says what
  // an uncrashed turn's reply holds and says
  @Test(arguments: NotedStaging.cases)
  func shouldWriteTheSameNotesWhenKilledBeforeWhatStagingLeftWasSaved(_ staging: NotedStaging) async throws {
    let script = [World.reply(("reply", World.text("Done.")), ("changeSet", "[\(staging.ops.joined(separator: ","))]")), [ScriptedModelProvider.Step.failure(.authentication)]]
    let uncrashed = try await World.book(workspace: true)
    try await staging.prepare(uncrashed)
    let reference = try await World.engine(uncrashed.store, provider: ScriptedModelProvider(calls: script))
    _ = try World.reply(of: await reference.send(staging.message, session: World.session, novel: uncrashed.novel, choices: staging.choices).outcome())
    let expected = try await Crash.footprint(in: uncrashed.store)
    let vault = try await CrashVault.make(workspace: true)
    defer { vault.remove() }
    let book = try vault.open()
    try await staging.prepare(book)
    let engine = try await Crash.engine(book.store, provider: ScriptedModelProvider(calls: script), faults: World.faults(.crash, at: .staged))
    let handle = try await engine.send(staging.message, session: World.session, novel: book.novel, choices: staging.choices)
    #expect(await handle.outcome() == .interrupted)
    #expect(try await World.record(handle.turn, in: book.store)?.staged == nil)

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let relaunched = try await Crash.engine(launched.store, provider: idle)
    let finishing = try #require(try await relaunched.resumeInterruptedTurns().first)
    _ = try World.reply(of: await finishing.outcome())
    #expect(idle.requests.isEmpty)
    let reply = try #require(try await World.messages(in: launched.store).last)
    #expect(reply.held == staging.held?.rawValue && reply.applyNote == staging.applyNote)
    #expect(reply.content.hasPrefix("Done.\n\n") == staging.notesReply)
    #expect(try await Crash.footprint(in: launched.store) == expected)
    try await Crash.expectSettled(relaunched, launched.store)
  }

  // A staging step whose turn row is gone, as when a later turn's `LocalTurnStore.begin` superseded an ended turn, is cleared at launch
  @Test func shouldForgetAnOrphanedStagingStepAtLaunch() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let book = try vault.open()
    try await book.run { try TurnStagingMarks.record(.cards(proposal: nil), reply: UUID(), session: World.session, in: $0.database) }
    #expect(try await World.stepRows(in: book.store) == 1)

    let launched = try vault.open()
    #expect(try await Crash.engine(launched.store, provider: ScriptedModelProvider()).resumeInterruptedTurns().isEmpty)
    #expect(try await World.stepRows(in: launched.store) == 0)
  }
}
