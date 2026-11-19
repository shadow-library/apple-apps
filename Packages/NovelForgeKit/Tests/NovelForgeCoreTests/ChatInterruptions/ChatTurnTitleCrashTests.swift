import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

private let title = "Mara's dockside trade"

/// The vault's session upkeep, counting the namings that finished.
private final class CountedNaming: Sendable {
  private let finished = Mutex(0)
  private let vault: ChatSessionUpkeep

  init(_ store: VaultStore) {
    vault = .vault(store)
  }

  var seam: ChatSessionUpkeep {
    ChatSessionUpkeep(
      nameSession: { [self] session, novel, opening, turn, router in
        let calls = await vault.nameSession(session, novel, opening, turn, router)
        finished.withLock { $0 += 1 }
        return calls
      }, forgetRemovedChats: vault.forgetRemovedChats)
  }

  var count: Int { finished.withLock { $0 } }
}

private func autoTitle(in store: VaultStore) async throws -> String? {
  try await store.read { try ChatSessionRecord.read(id: World.session, in: $0).entry?.record.autoTitle }
}

private func owedNamings(in store: VaultStore) async throws -> [ChatSessionNaming] {
  let replica = store.replica
  return try await store.read { try LocalSessionNamings.owed(replica: replica, in: $0.database) }
}

// chat.service.ts:331: the opening message names its session beside the turn, and a crash on either side of the naming leaves the session named once
@Suite("Chat turns killed around the session's naming", .serialized, TestTimeLimit.standard)
struct ChatTurnTitleCrashTests {
  @Test func shouldNeitherNameAgainNorAskAgainWhenKilledAfterTheTitleWasWritten() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let named = Signal()
    let provider = KillableProvider(turns: [.answer(World.reply(("reply", World.text("Noted."))))], titles: [.answer(Crash.titled(title))], turnsWait: named)
    let engine = try await Crash.engine(
      killed.store, provider: provider, faults: World.faults(.crash, at: .settled), upkeep: Crash.naming(killed.store, named: named))
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    #expect(await handle.outcome() == .interrupted)
    #expect(try await autoTitle(in: killed.store) == title)
    await engine.namingsSettled()
    #expect(try await owedNamings(in: killed.store).isEmpty)

    let launched = try vault.open()
    #expect(try await World.record(handle.turn, in: launched.store)?.basis.namesSession == true)
    let idle = KillableProvider(turns: [])
    let naming = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: idle, upkeep: naming.seam)
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    #expect(try World.reply(of: await resumed.outcome()) == handle.turn)
    await relaunched.namingsSettled()
    #expect(naming.count == 0)
    #expect(idle.turnRequests.isEmpty && idle.titleRequests.isEmpty)
    #expect(try await autoTitle(in: launched.store) == title)
    try await Crash.expectOneReplyPerMessage(launched.store)
    try await Crash.expectSettled(relaunched, launched.store)
  }

  // The process ends with the title call and the turn's call both in flight: the resumed turn names the session, once
  @Test func shouldNameTheSessionWhenKilledWhileTheTitleCallWasInFlight() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.freeze(Crash.shown)], titles: [.freeze([])])
    let engine = try await Crash.engine(killed.store, provider: provider, upkeep: .vault(killed.store))
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    try await provider.waitFrozen(2)

    let launched = try vault.open()
    #expect(try await World.record(handle.turn, in: launched.store)?.basis.namesSession == true)
    let script = KillableProvider(turns: [.answer(World.reply(("reply", World.text("Noted."))))], titles: [.answer(Crash.titled(title))])
    let naming = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: script, upkeep: naming.seam)
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    #expect(try World.reply(of: await resumed.outcome()) == handle.turn)
    await relaunched.namingsSettled()
    #expect(naming.count == 1)
    #expect(script.titleRequests.count == 1 && script.turnRequests.count == 1)
    #expect(try await autoTitle(in: launched.store) == title)
    try await Crash.expectOneReplyPerMessage(launched.store)
  }

  // A resumed turn answering a message another device sent never names the session: that device does (chat.service.ts:331)
  @Test func shouldNotNameTheSessionWhenResumingAnAnswerToAMessageSentElsewhere() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let opening = try ChatWorld.message(content: World.message)
    try await killed.run { _ = try opening.append(in: &$0) }
    let provider = KillableProvider(turns: [.freeze(Crash.shown)])
    let engine = try await Crash.engine(killed.store, provider: provider, upkeep: .vault(killed.store))
    let handle = try await engine.answer(message: opening.id, session: World.session, novel: killed.novel)
    try await provider.waitFrozen()

    let launched = try vault.open()
    #expect(try await World.record(handle.turn, in: launched.store)?.basis.namesSession == false)
    let script = KillableProvider(turns: [.answer(World.reply(("reply", World.text("Noted."))))], titles: [.answer(Crash.titled(title))])
    let naming = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: script, upkeep: naming.seam)
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    _ = try World.reply(of: await resumed.outcome())
    await relaunched.namingsSettled()
    #expect(naming.count == 0 && script.titleRequests.isEmpty)
    #expect(try await autoTitle(in: launched.store) == nil)
  }

  // F27 1b: the reply was appended while the title call ran, then the process ended: no turn is left to resume, and the launch names the session once
  @Test func shouldNameTheSessionAtLaunchWhenKilledWhileTheTitleCallRanPastTheReply() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.answer(World.reply(("reply", World.text("Noted."))))], titles: [.freeze([])])
    let engine = try await Crash.engine(killed.store, provider: provider, upkeep: .vault(killed.store))
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    #expect(try World.reply(of: await handle.outcome()) == handle.turn)
    try await provider.waitFrozen()

    let launched = try vault.open()
    #expect(try await owedNamings(in: launched.store).map(\.opening) == [handle.userMessage])
    let script = KillableProvider(turns: [], titles: [.answer(Crash.titled(title))])
    let naming = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: script, upkeep: naming.seam)
    #expect(try await relaunched.resumeInterruptedTurns().isEmpty)
    await relaunched.namingsSettled()
    #expect(naming.count == 1)
    #expect(try await autoTitle(in: launched.store) == title)
    #expect(script.titleRequests.count == 1 && script.turnRequests.isEmpty)
    #expect(try await owedNamings(in: launched.store).isEmpty)
    try await Crash.expectOneReplyPerMessage(launched.store)

    let again = try vault.open()
    let idle = KillableProvider(turns: [])
    let counted = CountedNaming(again.store)
    let third = try await Crash.engine(again.store, provider: idle, upkeep: counted.seam)
    #expect(try await third.resumeInterruptedTurns().isEmpty)
    await third.namingsSettled()
    #expect(counted.count == 0 && idle.titleRequests.isEmpty)
  }

  // Killed after the title was written and before the naming recorded its end: the launch checks again, finds the session named and asks nothing
  @Test func shouldAskNoTitleAtLaunchWhenKilledAfterTheTitleWasWrittenPastTheReply() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let book = try vault.open()
    let opening = try ChatWorld.message(content: World.message)
    let naming = ChatSessionNaming(session: World.session, novel: book.novel, opening: opening.id, costTier: .balanced, contentMode: .standard)
    let replica = book.store.replica
    try await book.run { transaction in
      _ = try opening.append(in: &transaction)
      _ = try ChatAutoTitle.nameIfUntitled(World.session, novel: book.novel, title: title, in: &transaction)
      try LocalSessionNamings.owe(naming, replica: replica, in: transaction.database)
    }

    let launched = try vault.open()
    let idle = KillableProvider(turns: [], titles: [.answer(Crash.titled("Another name"))])
    let counted = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: idle, upkeep: counted.seam)
    #expect(try await relaunched.resumeInterruptedTurns().isEmpty)
    await relaunched.namingsSettled()
    #expect(counted.count == 1)
    #expect(try await owedNamings(in: launched.store).isEmpty)
    #expect(idle.titleRequests.isEmpty)
    #expect(try await autoTitle(in: launched.store) == title)
  }

  // F27 1d: a Resume tapped while the stopped run's title call is still in flight shares that naming instead of asking for a second title
  @Test func shouldAskNoSecondTitleWhenATurnResumesWhileItsNamingRuns() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let book = try vault.open()
    let provider = KillableProvider(
      turns: [.freeze(Crash.shown), .answer(World.reply(("reply", World.text("Noted."))))], titles: [.freeze([]), .answer(Crash.titled(title))])
    let engine = try await Crash.engine(book.store, provider: provider, upkeep: .vault(book.store))
    let handle = try await engine.send(World.message, session: World.session, novel: book.novel)
    try await provider.waitFrozen(2)
    engine.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)

    let resumed = try await engine.resume(turn: handle.turn)
    #expect(try World.reply(of: await resumed.outcome()) == handle.turn)
    #expect(provider.titleRequests.count == 1 && provider.turnRequests.count == 2)
    #expect(try await owedNamings(in: book.store).count == 1)
    #expect(try await autoTitle(in: book.store) == nil)
  }
}
