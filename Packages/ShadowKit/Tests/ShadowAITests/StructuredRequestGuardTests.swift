import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowAI

private struct ForbiddenRequest: ShadowError, Equatable {
  var code: String { "test.forbidden" }
  var errorDescription: String? { "The request carries a forbidden word." }
}

private enum Lookalike: ShadowError, Equatable {
  case some(Int)

  var code: String { "test.forbidden" }
  var errorDescription: String? { "The request carries a forbidden word." }
}

/// Refuses any request one of whose messages or system segments holds the word, and keeps every request it was shown.
private final class RecordingGuard: Sendable {
  static let systemLine = "Never cross the line."

  private let screened = Mutex<[ModelRequest]>([])
  private let word: String
  private let systemLine: String?

  init(refusing word: String = "FORBIDDEN", systemLine: String? = nil) {
    self.word = word
    self.systemLine = systemLine
  }

  var requests: [ModelRequest] { screened.withLock { $0 } }

  var guarded: ModelRequestGuard {
    ModelRequestGuard(systemLine: systemLine) { [self] request in
      screened.withLock { $0.append(request) }
      let texts = request.system.map(\.text) + request.messages.map(\.text)
      return texts.contains { $0.contains(word) } ? .refuse(ForbiddenRequest()) : .allow
    }
  }
}

private let refusal = ModelRequestRefusal(ForbiddenRequest())
private let forbiddenDescending = #"{"title":"FORBIDDEN","chapters":[2,1]}"#

private func systemLineCount(_ request: ModelRequest) -> Int {
  request.system.count(where: { $0.text == RecordingGuard.systemLine })
}

@Suite("Model request refusal")
struct ModelRequestRefusalTests {
  @Test("should compare refusals by their reasons' own equality")
  func comparesReasons() {
    #expect(ModelRequestRefusal(Lookalike.some(1)) == ModelRequestRefusal(Lookalike.some(1)))
    #expect(ModelRequestRefusal(Lookalike.some(1)) != ModelRequestRefusal(Lookalike.some(2)))
    #expect(ModelRequestRefusal(Lookalike.some(1)) != refusal)
  }

  @Test("should forward the reason's code and description and never retry")
  func forwardsReason() {
    let error = ModelError.requestRefused(refusal)
    #expect(error.code == "test.forbidden")
    #expect(error.errorDescription == "The request carries a forbidden word.")
    #expect(!error.isRetryable)
    #expect(StructuredError.model(error, responses: []).code == "test.forbidden")
  }

  @Test("should not retry a refused request")
  func notRetried() async {
    let base = ScriptedModelProvider(calls: [[.failure(.requestRefused(refusal))], ScriptedModelProvider.reply("Hi")])
    let retrying = RetryingProvider(base, clock: ManualClock(.advancesOnSleep), random: { 0 })

    let outcome = await RoutingFixture.drain(retrying.stream(StructuredStreamFixture.request))

    #expect(outcome.error == .requestRefused(refusal))
    #expect(base.requests.count == 1)
  }

  @Test("should put the system line first, once, and leave a request alone without one")
  func framesRequests() {
    let request = StructuredStreamFixture.request
    let framed = ModelRequestGuard(systemLine: "Line.") { _ in .allow }.framing(request)
    #expect(framed.system.map(\.text) == ["Line."] + request.system.map(\.text))
    #expect(framed.messages == request.messages)
    #expect(ModelRequestGuard { _ in .allow }.framing(request) == request)
  }
}

@Suite("StructuredCall request guard", TestTimeLimit.quick)
struct StructuredRequestGuardTests {
  private typealias Fixture = StructuredStreamFixture

  private struct Run {
    let outcome: Result<StructuredResult, StructuredStreamFailure>
    let events: [StructuredStreamEvent]

    var lines: [String] { events.map(Fixture.describe) }

    var failure: StructuredStreamFailure? {
      guard case .failure(let failure) = outcome else { return nil }
      return failure
    }
  }

  private static func stream(_ provider: any ModelProvider, request: ModelRequest = Fixture.request, native: Bool = false, guard requestGuard: ModelRequestGuard?) async
    -> Run
  {
    var events: [StructuredStreamEvent] = []
    do throws(StructuredStreamFailure) {
      let result = try await StructuredCall(provider: provider, supportsNativeSchema: native).stream(
        request, name: "outline", schema: Fixture.schema, review: Fixture.review, requestGuard: requestGuard, observer: { events.append($0) })
      return Run(outcome: .success(result), events: events)
    } catch {
      return Run(outcome: .failure(error), events: events)
    }
  }

  @Test("should refuse a first request before the provider sees it, showing no attempt")
  func refusesFirstRequest() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard()
    var request = Fixture.request
    request.system.insert(ContextSegment(text: "FORBIDDEN background"), at: 0)

    let run = await Self.stream(provider, request: request, guard: screen.guarded)

    #expect(provider.requests.isEmpty)
    #expect(run.lines == ["failed test.forbidden"])
    #expect(run.failure == StructuredStreamFailure(error: .model(.requestRefused(refusal), responses: []), partialText: "", callIDs: []))
    #expect(run.failure?.errorDescription == "The request carries a forbidden word.")
    #expect(screen.requests.count == 1)
    #expect(screen.requests.first?.messages.last?.text.hasSuffix(StructuredPrompt.schemaInstruction(name: "outline", schema: Fixture.schema)) == true)
  }

  @Test("should refuse a repair re-ask that carries the first reply back, after sending only the first request")
  func refusesRepair() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(forbiddenDescending)
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard()

    let run = await Self.stream(provider, guard: screen.guarded)

    #expect(provider.requests.count == 1)
    #expect(run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(forbiddenDescending) + ["failed test.forbidden"])
    #expect(
      run.failure
        == StructuredStreamFailure(error: .model(.requestRefused(refusal), responses: [Fixture.response(forbiddenDescending)]), partialText: "", callIDs: []))
    #expect(screen.requests.count == 2)
    #expect(screen.requests.first == provider.requests.first)
    #expect(screen.requests.last?.messages.dropLast().last == .assistant(forbiddenDescending))
  }

  @Test("should screen every request it sends, exactly as sent, when the guard allows them")
  func screensEveryAllowedRequest() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard()

    let run = await Self.stream(provider, guard: screen.guarded)

    let result = try run.outcome.get()
    #expect(result.wasRepaired)
    #expect(
      run.lines == ["attempt 1 prompt answer"] + Fixture.deltas(Fixture.descending) + ["attempt 2 prompt repair", "reset"] + Fixture.deltas(Fixture.ascending) + ["succeeded"])
    #expect(screen.requests == provider.requests)
    #expect(Fixture.requests(run.events) == provider.requests)
  }

  @Test("should send the guard's system line first, exactly once, in every attempt and show it in each")
  func framesEveryAttempt() async throws {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.descending)
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard(systemLine: RecordingGuard.systemLine)

    let run = await Self.stream(provider, guard: screen.guarded)

    #expect(try run.outcome.get().wasRepaired)
    #expect(provider.requests.count == 2)
    #expect(provider.requests.map(systemLineCount) == [1, 1])
    #expect(provider.requests.map { $0.system.first?.text } == [RecordingGuard.systemLine, RecordingGuard.systemLine])
    #expect(screen.requests.map(systemLineCount) == [0, 0])
    #expect(Fixture.requests(run.events) == provider.requests)
  }

  @Test("should behave with no guard exactly as with one that allows everything")
  func noGuardMatchesAllowingGuard() async throws {
    let unguarded = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.descending), ScriptedModelProvider.reply(Fixture.ascending)])
    let guarded = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.descending), ScriptedModelProvider.reply(Fixture.ascending)])

    let plain = await Self.stream(unguarded, guard: nil)
    let screened = await Self.stream(guarded, guard: ModelRequestGuard { _ in .allow })

    #expect(plain.events == screened.events)
    #expect(unguarded.requests == guarded.requests)
    #expect(try plain.outcome.get() == screened.outcome.get())
  }

  @Test("should screen the prompt-form request a native refusal falls back to")
  func screensFallback() async {
    let provider = ScriptedModelProvider(calls: [[.failure(.noEligibleModel)], ScriptedModelProvider.reply(Fixture.ascending)])
    let screened = Mutex<[ResponseFormat]>([])
    let promptOnly = ModelRequestGuard { request in
      screened.withLock { $0.append(request.format) }
      return request.format == .text ? .refuse(ForbiddenRequest()) : .allow
    }

    let run = await Self.stream(provider, native: true, guard: promptOnly)

    #expect(provider.requests.count == 1)
    #expect(screened.withLock { $0.count } == 2)
    #expect(run.lines == ["attempt 1 native answer", "failed test.forbidden"])
    #expect(run.failure?.error == .model(.requestRefused(refusal), responses: []))
  }

  @Test("should not fall back to the prompt form when the native request is refused")
  func refusedNativeDoesNotFallBack() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard(refusing: "Outline")

    let run = await Self.stream(provider, native: true, guard: screen.guarded)

    #expect(provider.requests.isEmpty)
    #expect(screen.requests.count == 1)
    #expect(run.failure?.error == .model(.requestRefused(refusal), responses: []))
  }

  @Test("should report a cancelled call as cancelled without asking the guard")
  func cancellationComesFirst() async {
    let provider = ScriptedModelProvider()
    provider.enqueueReply(Fixture.ascending)
    let screen = RecordingGuard(refusing: "Outline")

    let run = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await Self.stream(provider, guard: screen.guarded)
    }.value

    #expect(run.failure?.error == .model(.cancelled, responses: []))
    #expect(screen.requests.isEmpty)
    #expect(provider.requests.isEmpty)
  }

  @Test("should screen a request once however often the provider retries it")
  func retriesScreenedOnce() async throws {
    let base = ScriptedModelProvider(calls: [[.failure(.overloaded(retryAfter: nil))], ScriptedModelProvider.reply(Fixture.ascending)])
    let retrying = RetryingProvider(base, clock: ManualClock(.advancesOnSleep), random: { 0 })
    let screen = RecordingGuard()

    let run = await Self.stream(retrying, guard: screen.guarded)

    #expect(try run.outcome.get().json == Data(Fixture.ascending.utf8))
    #expect(base.requests.count == 2)
    #expect(base.requests.first == base.requests.last)
    #expect(screen.requests == [base.requests[0]])
  }

  @Test("should throw the refusal from run with the guard's code")
  func runThrowsRefusal() async {
    let provider = ScriptedModelProvider()
    let screen = RecordingGuard(refusing: "Outline")

    await #expect(throws: StructuredError.model(.requestRefused(refusal), responses: [])) {
      try await StructuredCall(provider: provider, supportsNativeSchema: false).run(
        Fixture.request, name: "outline", schema: Fixture.schema, requestGuard: screen.guarded)
    }
    #expect(provider.requests.isEmpty)
  }
}

@Suite("RoutedCall request guard", TestTimeLimit.quick)
struct RoutedRequestGuardTests {
  private typealias Fixture = StructuredStreamFixture

  private static func prepare(
    _ provider: any ModelProvider, guard requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?, mode: ModelContentMode = .standard
  ) async throws -> (call: RoutedCall, store: VaultStore) {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    for kind in ModelProviderKind.allCases { try await RoutingFixture.grantConsent(host: RoutingFixture.binding(kind, provider).host, in: store) }
    let router = RoutingFixture.router(
      RoutingFixture.configuration(.anthropic), anthropic: provider, openRouter: provider, store: store, clock: clock, requestGuard: requestGuard)
    return (try await router.prepare(RoutingFixture.call(mode: mode)), store)
  }

  private static func ask(_ call: RoutedCall, system: String = "You outline novels.") -> ModelRequest {
    call.request(system: [ContextSegment(text: system)], messages: [.user("Outline the novel.")])
  }

  private static func stream(_ call: RoutedCall, _ request: ModelRequest) async -> (
    outcome: Result<StructuredResult, StructuredStreamFailure>, events: [StructuredStreamEvent]
  ) {
    var events: [StructuredStreamEvent] = []
    do throws(StructuredStreamFailure) {
      let result = try await call.streamStructured(request, name: "outline", schema: Fixture.schema, review: Fixture.review, observer: { events.append($0) })
      return (.success(result), events)
    } catch {
      return (.failure(error), events)
    }
  }

  @Test("should refuse a request streamed straight through the provider, neither sending nor ledgering it")
  func refusesDirectStream() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("Hi")])
    let screen = RecordingGuard()
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    let outcome = await RoutingFixture.drain(call.provider.stream(Self.ask(call, system: "FORBIDDEN")))
    await call.settled()

    #expect(outcome.events.isEmpty)
    #expect(outcome.error == .requestRefused(refusal))
    #expect(base.requests.isEmpty)
    #expect(call.callIDs.isEmpty)
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }

  @Test("should send an allowed direct stream with the system line first, once, and ledger it")
  func framesDirectStream() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("Hi")])
    let screen = RecordingGuard(systemLine: RecordingGuard.systemLine)
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    let outcome = await RoutingFixture.drain(call.provider.stream(Self.ask(call)))
    await call.settled()

    #expect(outcome.error == nil)
    #expect(base.requests.map { $0.system.map(\.text) } == [[RecordingGuard.systemLine, "You outline novels."]])
    #expect(screen.requests == [Self.ask(call)])
    #expect(try await LedgerFixture.entries(store).count == 1)
  }

  @Test("should leave a route unguarded when the policy gives it no guard")
  func nilPolicyUnguarded() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply("Hi")])
    let (call, store) = try await Self.prepare(base, guard: { _ in nil })

    let outcome = await RoutingFixture.drain(call.provider.stream(Self.ask(call, system: "FORBIDDEN")))
    await call.settled()

    #expect(call.requestGuard == nil)
    #expect(outcome.error == nil)
    #expect(base.requests == [Self.ask(call, system: "FORBIDDEN")])
    #expect(try await LedgerFixture.entries(store).count == 1)
  }

  @Test("should ask the policy for each route's guard", arguments: [ModelContentMode.standard, .unrestricted])
  func guardsByRoute(mode: ModelContentMode) async throws {
    let screen = RecordingGuard()
    let (call, _) = try await Self.prepare(ScriptedModelProvider(), guard: { $0.contentMode == .unrestricted ? screen.guarded : nil }, mode: mode)

    #expect((call.requestGuard != nil) == (mode == .unrestricted))
    #expect(call.route.contentMode == mode)
  }

  @Test("should neither send nor ledger a refused first structured request")
  func refusedFirstRequestCostsNothing() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.ascending)])
    let screen = RecordingGuard()
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    let run = await Self.stream(call, Self.ask(call, system: "FORBIDDEN"))
    await call.settled()

    #expect(run.outcome == .failure(StructuredStreamFailure(error: .model(.requestRefused(refusal), responses: []), partialText: "", callIDs: [])))
    #expect(run.events.map(Fixture.describe) == ["failed test.forbidden"])
    #expect(base.requests.isEmpty)
    #expect(call.callIDs.isEmpty)
    #expect(call.entries.isEmpty)
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }

  @Test("should refuse a repair re-ask on a guarded route and ledger only the first request")
  func refusedRepairLedgersOnlyTheFirst() async throws {
    let base = ScriptedModelProvider(calls: [
      ScriptedModelProvider.reply(forbiddenDescending, generationID: "g1"), ScriptedModelProvider.reply(Fixture.ascending, generationID: "g2"),
    ])
    let screen = RecordingGuard(systemLine: RecordingGuard.systemLine)
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    let run = await Self.stream(call, Self.ask(call))
    await call.settled()

    guard case .failure(let failure) = run.outcome, case .model(.requestRefused(let refused), let responses) = failure.error else {
      Issue.record("expected the repair to be refused, got \(run.outcome)")
      return
    }
    #expect(refused == refusal)
    #expect(responses.map(\.text) == [forbiddenDescending])
    #expect(responses.map(\.generationID) == ["g1"])
    #expect(failure.code == "test.forbidden")
    #expect(failure.partialText.isEmpty)
    #expect(failure.callIDs.count == 1)
    #expect(failure.callIDs == call.callIDs)
    #expect(base.requests.count == 1)
    #expect(base.requests.map(systemLineCount) == [1])
    #expect(screen.requests.count == 2)
    let entries = try await LedgerFixture.entries(store)
    #expect(entries.map(\.id) == failure.callIDs)
    #expect(entries.map(\.outcome) == [.finished])
  }

  @Test("should send every allowed structured request with the system line exactly once and ledger each")
  func allowedRequestsFramedOnce() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.descending), ScriptedModelProvider.reply(Fixture.ascending)])
    let screen = RecordingGuard(systemLine: RecordingGuard.systemLine)
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    let run = await Self.stream(call, Self.ask(call))
    await call.settled()

    let result = try run.outcome.get()
    #expect(result.wasRepaired)
    #expect(base.requests.map(systemLineCount) == [1, 1])
    #expect(base.requests.map { $0.system.first?.text } == [RecordingGuard.systemLine, RecordingGuard.systemLine])
    #expect(screen.requests.map(systemLineCount) == [0, 0])
    #expect(Fixture.requests(run.events) == base.requests)
    #expect(result.callIDs.count == 2)
    #expect(Set(try await LedgerFixture.entries(store).map(\.id)) == Set(result.callIDs))
  }

  @Test("should throw the refusal from structured on a guarded route without sending anything")
  func structuredThrowsRefusal() async throws {
    let base = ScriptedModelProvider(calls: [ScriptedModelProvider.reply(Fixture.ascending)])
    let screen = RecordingGuard(refusing: "Outline")
    let (call, store) = try await Self.prepare(base, guard: { _ in screen.guarded })

    await #expect(throws: StructuredError.model(.requestRefused(refusal), responses: [])) {
      try await call.structured(Self.ask(call), name: "outline", schema: Fixture.schema)
    }
    await call.settled()
    #expect(base.requests.isEmpty)
    #expect(try await LedgerFixture.entries(store).isEmpty)
  }
}
