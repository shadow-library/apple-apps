import Foundation
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowAI

@Suite("RoutedCall ledgering", TestTimeLimit.quick)
struct RoutedCallTests {
  private static let host = "api.example.com"

  private static func prepare(
    _ provider: any ModelProvider, kind: ModelProviderKind = .anthropic, call: TaskCall = RoutingFixture.call(), openRouterModels: [RemoteModel] = [],
    clock: LedgerTestClock = LedgerTestClock(), store: VaultStore? = nil
  ) async throws -> (call: RoutedCall, store: VaultStore) {
    let store = try store ?? LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: RoutingFixture.binding(kind, provider).host, in: store)
    let configuration = RoutingFixture.configuration(kind, openRouterModels: openRouterModels)
    let router = RoutingFixture.router(
      configuration, anthropic: kind == .anthropic ? provider : nil, openRouter: kind == .openRouter ? provider : nil, store: store, clock: clock)
    return (try await router.prepare(call), store)
  }

  private static func ask(_ call: RoutedCall) -> ModelRequest {
    call.request(system: [ContextSegment(text: "You help an author.")], messages: [.user("Name the chapter.")])
  }

  @Test("should begin and finish one ledger entry per stream and report its id")
  func ledgersOneCall() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("The Ferry", usage: TokenUsage(input: 100, output: 20), requestID: "r1")])
    let (call, store) = try await Self.prepare(base, call: RoutingFixture.call(.helper, pace: .meticulous, deeper: true))
    let response = try await call.provider.stream(Self.ask(call)).collect()
    await call.settled()
    #expect(response.text == "The Ferry")
    let entries = try await LedgerFixture.entries(store)
    let entry = try #require(entries.first)
    #expect(entries.count == 1)
    #expect(call.callIDs == [entry.id])
    #expect(call.entries == entries)
    #expect(entry.provider == Self.host)
    #expect(entry.model == "model-meticulous")
    #expect(entry.task == .helper)
    #expect(entry.pace == .meticulous)
    #expect(entry.outcome == .finished)
    #expect(entry.requestID == "r1")
    #expect(entry.costSource == .computed)
    #expect(base.requests.first?.effort == .xhigh)
    #expect(base.requests.first?.maxOutputTokens == 600)
  }

  @Test("should record retried attempts as child entries of the call")
  func retriesAreChildren() async throws {
    let base = ScriptedModelProvider(calls: [
      [.event(.started(requestID: "r1", generationID: "g1")), .failure(.server(status: 502))],
      [.failure(.overloaded(retryAfter: nil))],
      ScriptedModelProvider.reply("ok", requestID: "r3", generationID: "g3"),
    ])
    let retrying = RetryingProvider(base, policy: RetryPolicy(maxAttempts: 4), clock: ManualClock(.advancesOnSleep), random: { 0 })
    let (call, store) = try await Self.prepare(retrying, kind: .openRouter)
    _ = try await call.provider.stream(Self.ask(call)).collect()
    await call.settled()

    let entries = try await LedgerFixture.entries(store)
    let parentID = try #require(call.callIDs.first)
    #expect(call.callIDs.count == 1)
    let parent = try #require(entries.first { $0.id == parentID })
    #expect(parent.outcome == .finished)
    #expect(parent.generationID == "g3")
    let children = entries.filter { $0.parent == parentID }
    #expect(children.count == 1)
    #expect(children.first?.id == Ledger.attemptID(of: parentID, index: 0))
    #expect(children.first?.generationID == "g1")
    #expect(children.first?.outcome == .failed)
    #expect(children.first?.costSource == .pending)
    #expect(entries.count == 2)
    #expect(Set(call.entries.map(\.id)) == Set(entries.map(\.id)))
    #expect(base.requests.count == 3)
  }

  @Test("should leave a cancelled call begun with its ids, so its cost stays pending")
  func cancelLeavesPending() async throws {
    let clock = LedgerTestClock()
    let base = ScriptedModelProvider(
      calls: [[.event(.started(requestID: "r1", generationID: "g1")), .text("Half a"), .delay(.seconds(60)), .text(" reply")]], clock: ManualClock(.manual))
    let (call, store) = try await Self.prepare(base, kind: .openRouter, clock: clock)
    for try await event in call.provider.stream(Self.ask(call)) {
      if case .textDelta = event { break }
    }
    await call.settled()

    let entries = try await LedgerFixture.entries(store)
    let entry = try #require(entries.first)
    #expect(entries.count == 1)
    #expect(call.callIDs == [entry.id])
    #expect(call.entries == entries)
    #expect(entry.outcome == .started)
    #expect(entry.requestID == "r1")
    #expect(entry.generationID == "g1")
    #expect(entry.costSource == .pending)
    #expect(Spend.summary(of: entries, now: clock.now, calendar: RoutingFixture.utc).pendingCalls == 1)
  }

  @Test("should still close a call whose consumer stops right after it finished")
  func stopAfterFinished() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("Done", requestID: "r1")])
    let (call, store) = try await Self.prepare(base)
    for try await event in call.provider.stream(Self.ask(call)) {
      if case .finished = event { break }
    }
    await call.settled()
    #expect(try await LedgerFixture.entries(store).map(\.outcome) == [.finished])
    #expect(call.entries.map(\.outcome) == [.finished])
  }

  @Test("should write the attempts a call abandoned before it was cancelled, leaving the call pending")
  func cancelDuringBackoff() async throws {
    let base = ScriptedModelProvider(calls: [[.event(.started(requestID: "r1", generationID: "g1")), .failure(.server(status: 502))], ScriptedModelProvider.reply("late")])
    let retrying = RetryingProvider(base, policy: RetryPolicy(maxAttempts: 4), clock: ManualClock(.manual), random: { 0 })
    let (call, store) = try await Self.prepare(retrying, kind: .openRouter)
    for try await event in call.provider.stream(Self.ask(call)) {
      if case .retrying = event { break }
    }
    await call.settled()

    let entries = try await LedgerFixture.entries(store)
    let parentID = try #require(call.callIDs.first)
    let parent = try #require(entries.first { $0.id == parentID })
    #expect(parent.outcome == .started)
    #expect(parent.generationID == nil)
    #expect(parent.costSource == .pending)
    let child = try #require(entries.first { $0.parent == parentID })
    #expect(child.id == Ledger.attemptID(of: parentID, index: 0))
    #expect(child.generationID == "g1")
    #expect(child.outcome == .failed)
    #expect(child.costSource == .pending)
    #expect(entries.count == 2)
    #expect(Set(call.entries.map(\.id)) == Set(entries.map(\.id)))
    #expect(base.requests.count == 1)
  }

  @Test("should settle only once a stream cancelled while it waits for the provider has been left pending")
  func settlesAfterCancelledWait() async throws {
    let clock = ManualClock(.manual)
    let base = ScriptedModelProvider(calls: [[.delay(.seconds(60))] + ScriptedModelProvider.reply("late")], clock: clock)
    let (call, store) = try await Self.prepare(base, kind: .openRouter)
    let stream = call.provider.stream(Self.ask(call))
    let consumer = Task { await RoutingFixture.drain(stream) }
    await clock.waitForSleepers(1)
    consumer.cancel()
    #expect(await consumer.value.error == .cancelled)
    await call.settled()

    let entries = try await LedgerFixture.entries(store)
    #expect(entries.map(\.outcome) == [.started])
    #expect(entries.map(\.costSource) == [.pending])
    #expect(call.entries == entries)
    #expect(call.callIDs == entries.map(\.id))
  }

  @Test("should never settle before a stream cancelled at its first iteration has closed", arguments: 0..<40)
  func settlesAfterEarlyCancel(round: Int) async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("x")])
    let (call, store) = try await Self.prepare(base)
    let stream = call.provider.stream(Self.ask(call))
    let consumer = Task { await RoutingFixture.drain(stream) }
    consumer.cancel()
    _ = await consumer.value
    await call.settled()

    let entries = try await LedgerFixture.entries(store)
    #expect(call.entries == entries)
    #expect(call.callIDs == entries.map(\.id))
    #expect(base.requests.count <= entries.count)
  }

  @Test("should not send a call the ledger cannot record, blaming the ledger rather than the provider")
  func beginFailure() async throws {
    let clock = LedgerTestClock()
    let registry = SchemaRegistry(version: 1, entities: LedgerSchema.entities.filter { $0.kind == LedgerSchema.consentKind })
    let store = try VaultStore.open(.inMemory, registry: registry, wallClock: clock.function)
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("x")])
    let (call, _) = try await Self.prepare(base, clock: clock, store: store)
    let outcome = await RoutingFixture.drain(call.provider.stream(Self.ask(call)))
    await call.settled()
    #expect(outcome.error == .notRecorded)
    #expect(base.requests.isEmpty)
    #expect(call.callIDs.isEmpty)
  }

  @Test("should close a failed call with its ids")
  func failedCall() async throws {
    let base = ScriptedModelProvider(calls: [[.event(.started(requestID: "r1", generationID: "g1")), .text("Par"), .failure(.midStream(code: "x", message: "gone"))]])
    let (call, store) = try await Self.prepare(base, kind: .openRouter)
    let outcome = await RoutingFixture.drain(call.provider.stream(Self.ask(call)))
    #expect(outcome.error == .midStream(code: "x", message: "gone"))
    await call.settled()
    let entry = try #require(try await LedgerFixture.entries(store).first)
    #expect(entry.outcome == .failed)
    #expect(entry.generationID == "g1")
    #expect(entry.costSource == .pending)
    #expect(call.entries == [entry])
  }

  @Test("should write nothing for a stream that is never iterated")
  func lazyBegin() async throws {
    let base = ScriptedModelProvider()
    let (call, store) = try await Self.prepare(base)
    _ = call.provider.stream(Self.ask(call))
    #expect(try await LedgerFixture.entries(store).isEmpty)
    #expect(call.callIDs.isEmpty)
  }

  @Test("should refuse a request for a model other than the route's, sending and recording nothing")
  func foreignModel() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("x")])
    let (call, store) = try await Self.prepare(base)
    var request = Self.ask(call)
    request.model = "model-swift"
    let outcome = await RoutingFixture.drain(call.provider.stream(request))
    guard case .invalidRequest? = outcome.error else {
      Issue.record("expected invalidRequest, got \(String(describing: outcome.error))")
      return
    }
    #expect(base.requests.isEmpty)
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }

  @Test("should fall back to the prompt form when native schema mode finds no eligible model")
  func nativeFallsBackToPrompt() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.noEligibleModel)], ScriptedModelProvider.reply(#"{"answer":"yes"}"#, generationID: "g2")])
    let (call, store) = try await Self.prepare(base, kind: .openRouter, openRouterModels: [RemoteModel(id: "or/steady", supportsJSONSchema: true)])
    let result = try await call.structured(Self.ask(call), name: "answer", schema: RoutingFixture.schema)
    #expect(result.mode == .prompt)
    #expect(String(decoding: result.json, as: UTF8.self) == #"{"answer":"yes"}"#)
    guard case .json? = base.requests.first?.format else {
      Issue.record("expected the first request in native mode")
      return
    }
    #expect(base.requests.last?.format == .text)
    #expect(call.callIDs.count == 2)
    await call.settled()
    let entries = try await LedgerFixture.entries(store)
    #expect(Set(entries.map(\.outcome)) == [.failed, .finished])
  }

  @Test("should not repeat a prompt-form call that finds no eligible model")
  func promptDoesNotRepeat() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.noEligibleModel)]])
    let (call, _) = try await Self.prepare(base, kind: .openRouter, openRouterModels: [RemoteModel(id: "or/steady", supportsJSONSchema: false)])
    do {
      _ = try await call.structured(Self.ask(call), name: "answer", schema: RoutingFixture.schema)
      Issue.record("expected a failure")
    } catch {
      guard case .model(.noEligibleModel, _) = error else {
        Issue.record("expected noEligibleModel, got \(error)")
        return
      }
    }
    #expect(base.requests.count == 1)
  }
}
