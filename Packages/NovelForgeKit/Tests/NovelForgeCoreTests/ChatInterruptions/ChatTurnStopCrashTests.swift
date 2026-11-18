import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld
private typealias Crash = CrashWorld

/// Keys that are only answered once the asking task is cancelled, and then not at all: a turn stopped while it routes.
private struct StalledCredentials: ModelCredentialSource {
  let asked: Signal

  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    asked.raise()
    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
    return nil
  }
}

// RULE E07 (F27 follow-up 1a): the author's Stop is stored as it is asked for, so a process that ends before the turn records its end leaves a turn the next
// launch ends cancelled with what it showed, never one it resumes; an answer that had settled is still appended, as Stop leaves it
@Suite("Chat turns stopped and killed", .serialized, .timeLimit(.minutes(3)))
struct ChatTurnStopCrashTests {
  @Test func shouldEndAStoppedTurnCancelledWithItsTextWhenKilledBeforeItsEnd() async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.freeze(Crash.shown)])
    let engine = try await Crash.engine(killed.store, provider: provider, faults: World.faults(.crash, at: .ending))
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    #expect(!Crash.hasDelta(try await killed.store.localTurnFrames(handle.turn)))
    engine.cancel(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)
    let store = killed.store
    try await World.eventually("the stop reaches the file") { try await store.localTurn(handle.turn)?.stopped == true }
    let stored = try await killed.store.localTurnFrames(handle.turn)
    #expect(Crash.hasDelta(stored) && Crash.sequences(stored) == Crash.contiguous(stored.count))

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let relaunched = try await Crash.engine(launched.store, provider: idle)
    #expect(try await relaunched.resumeInterruptedTurns().isEmpty)
    let local = try #require(try await launched.store.localTurn(handle.turn))
    #expect(local.state == .cancelled && local.failure == nil && !local.stopped)
    #expect(try await launched.store.localTurnFrames(handle.turn) == stored)
    #expect(try await relaunched.activity(session: World.session) == .ended(local))
    #expect(try await World.messages(in: launched.store).map(\.role) == [.known(.user)])
    #expect(idle.requests.isEmpty && provider.turnRequests.count == 1)

    let answering = try await Crash.engine(launched.store, provider: ScriptedModelProvider(calls: [Crash.split()]))
    #expect(try World.reply(of: await answering.retry(turn: handle.turn).outcome()) == handle.turn)
    try await Crash.expectOneReplyPerMessage(launched.store)
    let again = try vault.open()
    let settled = try await Crash.engine(again.store, provider: idle)
    #expect(try await settled.resumeInterruptedTurns().isEmpty)
    try await Crash.expectSettled(settled, again.store)
  }

  @Test func shouldFinishAStoppedTurnWhoseAnswerHadSettledWhenKilled() async throws {
    let expected = try await Crash.uncrashed([Crash.split()])
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let engine = try await Crash.engine(killed.store, provider: ScriptedModelProvider(calls: [Crash.split()]), faults: World.faults(.crash, at: .settled))
    let handle = try await engine.send(World.message, session: World.session, novel: killed.novel)
    #expect(await handle.outcome() == .interrupted)
    try await killed.run { try LocalTurnStore.markStopped(handle.turn, at: Date(), in: $0.database) }
    #expect(try await killed.store.localTurn(handle.turn)?.stopped == true)

    let launched = try vault.open()
    let idle = ScriptedModelProvider()
    let relaunched = try await Crash.engine(launched.store, provider: idle)
    let resumed = try await relaunched.resumeInterruptedTurns()
    #expect(resumed.map(\.turn) == [handle.turn])
    #expect(try World.reply(of: await resumed[0].outcome()) == handle.turn)
    #expect(idle.requests.isEmpty)
    #expect(try await Crash.footprint(in: launched.store) == expected)
    try await Crash.expectOneReplyPerMessage(launched.store)
    try await Crash.expectSettled(relaunched, launched.store)
  }

  // A stop whose write is still on its way when the author retries the turn under the same id never marks the retried run
  @Test func shouldNotMarkARetriedRunStoppedByTheStopOfTheRunBeforeIt() async throws {
    let book = try await World.book()
    let (held, written) = (Signal(), Signal())
    var faults = ChatTurnEngine.Faults.none
    faults.stopWrite = { write in
      await held.wait()
      await write()
      written.raise()
    }
    let provider = KillableProvider(turns: [.freeze(Crash.shown), .freeze(Crash.shown)])
    let engine = try await Crash.engine(book.store, provider: provider, faults: faults)
    let first = try await engine.send(World.message, session: World.session, novel: book.novel)
    try await provider.waitFrozen()
    engine.cancel(turn: first.turn)
    #expect(await first.outcome() == .cancelled)
    let retried = try await engine.retry(turn: first.turn)
    try await provider.waitFrozen(2)
    held.raise()
    await written.wait()
    #expect(try await book.store.localTurn(first.turn)?.stopped == false)
    #expect(try await book.store.localTurn(first.turn)?.state == .pending)
    engine.interrupt(turn: retried.turn)
    #expect(await retried.outcome() == .interrupted)
  }

  // From the E08 review: a turn stopped while its resumed run routes ends as the stop says, never as a routing failure
  @Test(arguments: [false, true])
  func shouldEndATurnStoppedWhileItRoutesAsTheStopSays(cancelled: Bool) async throws {
    let vault = try await CrashVault.make()
    defer { vault.remove() }
    let killed = try vault.open()
    let provider = KillableProvider(turns: [.freeze([])])
    let handle = try await Crash.engine(killed.store, provider: provider).send(World.message, session: World.session, novel: killed.novel)
    try await provider.waitFrozen()

    let launched = try vault.open()
    let asked = Signal()
    let idle = KillableProvider(turns: [])
    let engine = try await Crash.engine(launched.store, provider: idle, credentials: StalledCredentials(asked: asked))
    let resumed = try #require(try await engine.resumeInterruptedTurns().first)
    await asked.wait()
    if cancelled { engine.cancel(turn: resumed.turn) } else { engine.interrupt(turn: resumed.turn) }

    #expect(await resumed.outcome() == (cancelled ? .cancelled : .interrupted))
    #expect(try await launched.store.localTurn(handle.turn)?.state == (cancelled ? .cancelled : .pending))
    #expect(idle.turnRequests.isEmpty)
  }
}
