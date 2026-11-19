import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAI

private struct HookRefusal: Error {}

@Suite("Model call begin hook", TestTimeLimit.quick)
struct ModelCallHookTests {
  private static func prepare(_ provider: any ModelProvider) async throws -> (call: RoutedCall, store: VaultStore) {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: RoutingFixture.binding(.anthropic, provider).host, in: store)
    let router = RoutingFixture.router(RoutingFixture.configuration(.anthropic), anthropic: provider, store: store, clock: clock)
    return (try await router.prepare(RoutingFixture.call()), store)
  }

  private static func ask(_ call: RoutedCall) -> ModelRequest {
    call.request(system: [ContextSegment(text: "You outline novels.")], messages: [.user("Outline the novel.")])
  }

  @Test func shouldRunTheHookInsideTheWriteThatBeginsTheCall() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry")])
    let (call, store) = try await Self.prepare(base)
    let seen = Mutex<[(id: UUID, begun: Bool)]>([])
    let hook: ModelCallBeginHook = { id, transaction in
      let begun = try transaction.state(of: Ledger.ref(id)) != nil
      seen.withLock { $0.append((id, begun)) }
    }
    let outcome = await ModelCallHooks.$begin.withValue(hook) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    #expect(outcome.error == nil)
    #expect(seen.withLock { $0.map(\.id) } == call.callIDs)
    #expect(seen.withLock { $0.allSatisfy(\.begun) })
    #expect(try await LedgerFixture.entries(store).map(\.id) == call.callIDs)
  }

  @Test func shouldRollTheBeginBackAndSendNothingWhenTheHookThrows() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry")])
    let (call, store) = try await Self.prepare(base)
    let hook: ModelCallBeginHook = { _, _ in throw HookRefusal() }
    let outcome = await ModelCallHooks.$begin.withValue(hook) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    #expect(outcome.error == .notRecorded)
    #expect(base.requests.isEmpty)
    #expect(call.callIDs.isEmpty)
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }

  @Test func shouldRunTheHookForEveryStreamOfARepairedStructuredCall() async throws {
    let base = ScriptedModelProvider(calls: [
      ScriptedModelProvider.reply(StructuredStreamFixture.descending), ScriptedModelProvider.reply(StructuredStreamFixture.ascending),
    ])
    let (call, _) = try await Self.prepare(base)
    let seen = Mutex<[UUID]>([])
    let hook: ModelCallBeginHook = { id, _ in seen.withLock { $0.append(id) } }
    let result = try await ModelCallHooks.$begin.withValue(hook) {
      try await call.streamStructured(Self.ask(call), name: "outline", schema: StructuredStreamFixture.schema, review: StructuredStreamFixture.review)
    }
    #expect(result.wasRepaired)
    #expect(seen.withLock { $0 } == result.callIDs)
  }

  @Test func shouldRunNoHookForAStreamCreatedOutsideTheHooksScope() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry")])
    let (call, _) = try await Self.prepare(base)
    let seen = Mutex(0)
    let stream = call.provider.stream(Self.ask(call))
    let hook: ModelCallBeginHook = { _, _ in seen.withLock { $0 += 1 } }
    let outcome = await ModelCallHooks.$begin.withValue(hook) { await RoutingFixture.drain(stream) }
    #expect(outcome.error == nil)
    #expect(seen.withLock { $0 } == 0)
  }
}
