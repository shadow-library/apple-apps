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

// chat.service.ts:331: the opening message names its session beside the turn, and a crash on either side of the naming leaves the session named once
@Suite("Chat turns killed around the session's naming", .serialized, .timeLimit(.minutes(3)))
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

    let launched = try vault.open()
    #expect(try await World.record(handle.turn, in: launched.store)?.basis.namesSession == true)
    let idle = KillableProvider(turns: [])
    let naming = CountedNaming(launched.store)
    let relaunched = try await Crash.engine(launched.store, provider: idle, upkeep: naming.seam)
    let resumed = try #require(try await relaunched.resumeInterruptedTurns().first)
    #expect(try World.reply(of: await resumed.outcome()) == handle.turn)
    try await World.eventually("the resumed turn's naming check finished") { naming.count == 1 }
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
    try await World.eventually("the resumed turn named its session") { naming.count == 1 }
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
    #expect(naming.count == 0 && script.titleRequests.isEmpty)
    #expect(try await autoTitle(in: launched.store) == nil)
  }
}
