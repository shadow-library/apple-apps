import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private typealias World = EngineWorld

private let stalled: [ScriptedModelProvider.Step] = [.event(.started(requestID: "req", generationID: nil)), .text(#"{"reply":"Thinking it. "#), .delay(.seconds(120))]

private func merged(_ events: [TurnStreamEvent]) -> [TurnStreamEvent] {
  var out = [TurnStreamEvent]()
  for event in events {
    if case .delta(let text) = event, case .delta(let earlier)? = out.last {
      out[out.count - 1] = .delta(earlier + text)
    } else {
      out.append(event)
    }
  }
  return out
}

// From the F22b review, round 2: a second Resume while one runs, and a resumed turn shows live exactly what it stores
@Suite("Chat turn resume cases", TestTimeLimit.standard)
struct ChatTurnResumeCaseTests {
  @Test func shouldKeepAResumedTurnPendingWhenResumeIsTappedTwice() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Go.", session: World.session, novel: book.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)

    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled, stalled]))
    async let a = Result { () async throws(ChatTurnError) in try await engine.resume(turn: handle.turn) }
    async let b = Result { () async throws(ChatTurnError) in try await engine.resume(turn: handle.turn) }
    let results = await [a, b]
    let running = results.compactMap { try? $0.get() }
    #expect(running.count == 1)
    let local = try await World.localTurn(handle.turn, in: book.store)
    #expect(local?.state == .pending)
    for handle in running {
      engine.interrupt(turn: handle.turn)
      _ = await handle.outcome()
    }
    #expect(try await World.localTurn(handle.turn, in: book.store)?.state == .pending)
  }

  @Test func shouldShowLiveExactlyWhatItStoresAcrossAResume() async throws {
    let book = try await World.book()
    let first = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let handle = try await first.send("Go.", session: World.session, novel: book.novel)
    for await event in handle.events {
      if case .delta = event { break }
    }
    first.interrupt(turn: handle.turn)
    #expect(await handle.outcome() == .interrupted)

    let engine = try await World.engine(book.store, provider: ScriptedModelProvider(calls: [stalled]))
    let resumed = try await engine.resume(turn: handle.turn)
    for await event in resumed.events {
      if case .delta = event { break }
    }
    let live = try await engine.observe(turn: handle.turn)
    engine.cancel(turn: handle.turn)
    #expect(await resumed.outcome() == .cancelled)
    var seen = [TurnStreamEvent]()
    for await event in live { seen.append(event) }
    let stored = try await book.store.localTurnFrames(handle.turn).compactMap(\.decoded)
    #expect(merged(seen) == merged(stored))
  }
}
