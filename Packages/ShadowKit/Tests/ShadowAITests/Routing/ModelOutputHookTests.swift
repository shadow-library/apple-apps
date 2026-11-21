import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAI

@Suite("Model call output hook", TestTimeLimit.quick)
struct ModelOutputHookTests {
  private final class Recorder: Sendable {
    private let seen = Mutex<[ModelOutputEvent]>([])
    var events: [ModelOutputEvent] { seen.withLock { $0 } }
    var observer: ModelOutputObserver { { [self] event in seen.withLock { $0.append(event) } } }
  }

  private static func prepare(_ provider: any ModelProvider) async throws -> RoutedCall {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: RoutingFixture.binding(.anthropic, provider).host, in: store)
    let router = RoutingFixture.router(RoutingFixture.configuration(.anthropic), anthropic: provider, store: store, clock: clock)
    return try await router.prepare(RoutingFixture.call())
  }

  private static func ask(_ call: RoutedCall) -> ModelRequest {
    call.request(system: [ContextSegment(text: "You outline novels.")], messages: [.user("Outline the novel.")])
  }

  @Test func shouldReportStartDeltasAndFinishInOrderWithProviderUsage() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry crosses", usage: TokenUsage(input: 10, output: 7))])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let outcome = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(outcome.error == nil)
    #expect(
      recorder.events == [
        .started(call: id, maxOutputTokens: base.requests[0].maxOutputTokens),
        .delta(call: id, estimatedTokens: 1),
        .delta(call: id, estimatedTokens: 2),
        .delta(call: id, estimatedTokens: 2),
        .finished(call: id, outputTokens: 7, outcome: .completed),
      ])
  }

  @Test func shouldReportARetriedAttemptAsFailedAndStartAgain() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.server(status: 502))], ScriptedModelProvider.reply("ok", usage: TokenUsage(input: 1, output: 3))])
    let retrying = RetryingProvider(base, policy: RetryPolicy(maxAttempts: 3), clock: ManualClock(.advancesOnSleep), random: { 0 })
    let call = try await Self.prepare(retrying)
    let recorder = Recorder()
    _ = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    let maxTokens = base.requests[0].maxOutputTokens
    #expect(
      recorder.events == [
        .started(call: id, maxOutputTokens: maxTokens),
        .finished(call: id, outputTokens: 0, outcome: .failed),
        .started(call: id, maxOutputTokens: maxTokens),
        .delta(call: id, estimatedTokens: 1),
        .finished(call: id, outputTokens: 3, outcome: .completed),
      ])
  }

  @Test func shouldReportEachStreamOfARepairedStructuredCallSeparately() async throws {
    let base = ScriptedModelProvider(calls: [
      ScriptedModelProvider.reply(StructuredStreamFixture.descending), ScriptedModelProvider.reply(StructuredStreamFixture.ascending),
    ])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let result = try await ModelCallHooks.$output.withValue(recorder.observer) {
      try await call.streamStructured(Self.ask(call), name: "outline", schema: StructuredStreamFixture.schema, review: StructuredStreamFixture.review)
    }
    #expect(result.wasRepaired)
    let events = recorder.events
    let starts = events.compactMap { if case .started(let id, _) = $0 { id } else { nil } }
    let finishes = events.compactMap { if case .finished(let id, _, let outcome) = $0 { (id, outcome) } else { nil } }
    #expect(starts == result.callIDs)
    #expect(finishes.map(\.0) == result.callIDs)
    #expect(finishes.allSatisfy { $0.1 == .completed })
    #expect(events.first.map { if case .started = $0 { true } else { false } } == true)
    #expect(events.last.map { if case .finished = $0 { true } else { false } } == true)
  }

  @Test func shouldReportACancelledFinishWithTheEstimateSoFar() async throws {
    let base = ScriptedModelProvider(
      calls: [[.event(.started(requestID: "r1", generationID: nil)), .text("Half"), .delay(.seconds(60)), .text(" reply")]], clock: ManualClock(.manual))
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let stream = ModelCallHooks.$output.withValue(recorder.observer) { call.provider.stream(Self.ask(call)) }
    for try await event in stream {
      if case .textDelta = event { break }
    }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(recorder.events.last == .finished(call: id, outputTokens: 1, outcome: .cancelled))
    #expect(recorder.events.count == 3)
  }

  @Test func shouldReportAFailedFinishWhenTheProviderFails() async throws {
    let base = ScriptedModelProvider(calls: [[.text("Half"), .failure(.server(status: 500))]])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let outcome = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(outcome.error != nil)
    #expect(recorder.events.last == .finished(call: id, outputTokens: 1, outcome: .failed))
  }

  @Test func shouldCallNothingWhenNoObserverIsSetOrTheStreamWasCreatedOutsideItsScope() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry")])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let stream = call.provider.stream(Self.ask(call))
    let outcome = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(stream) }
    #expect(outcome.error == nil)
    #expect(recorder.events.isEmpty)
  }

  @Test func shouldReportNothingForACallTheLedgerCouldNotRecord() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry")])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    let begin: ModelCallBeginHook = { _, _ in throw StoreError.database("refused") }
    let outcome = await ModelCallHooks.$begin.withValue(begin) {
      await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    }
    #expect(outcome.error == .notRecorded)
    #expect(recorder.events.isEmpty)
  }

  @Test func shouldKeepTheEstimateWhenTheProviderReportsNoOutputUsage() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry", usage: .zero)])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    _ = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(recorder.events.last == .finished(call: id, outputTokens: 3, outcome: .completed))
  }

  @Test func shouldReportAFailedFinishWhenTheStreamEndsWithoutFinishing() async throws {
    let base = ScriptedModelProvider(calls: [[.text("Half")]])
    let call = try await Self.prepare(base)
    let recorder = Recorder()
    _ = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(recorder.events.last == .finished(call: id, outputTokens: 1, outcome: .failed))
  }

  @Test func shouldNotRestartAnAttemptThatFailedAfterPartialText() async throws {
    let base = ScriptedModelProvider(calls: [[.text("Half"), .failure(.server(status: 502))], ScriptedModelProvider.reply("ok")])
    let retrying = RetryingProvider(base, policy: RetryPolicy(maxAttempts: 3), clock: ManualClock(.advancesOnSleep), random: { 0 })
    let call = try await Self.prepare(retrying)
    let recorder = Recorder()
    let outcome = await ModelCallHooks.$output.withValue(recorder.observer) { await RoutingFixture.drain(call.provider.stream(Self.ask(call))) }
    await call.settled()
    let id = try #require(call.callIDs.first)
    #expect(outcome.error != nil)
    #expect(
      recorder.events == [
        .started(call: id, maxOutputTokens: base.requests[0].maxOutputTokens),
        .delta(call: id, estimatedTokens: 1),
        .finished(call: id, outputTokens: 1, outcome: .failed),
      ])
  }
}
