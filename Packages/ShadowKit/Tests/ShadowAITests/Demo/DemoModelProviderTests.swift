import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import ShadowAI

enum DemoFixture {
  static let outline: JSONValue = [
    "type": "object",
    "properties": [
      "title": ["type": "string", "minLength": 3, "maxLength": 40],
      "chapters": ["type": "array", "minItems": 2, "items": ["type": "string", "minLength": 1]],
      "tone": ["enum": ["warm", "cold"]],
    ],
    "required": ["title", "chapters", "tone"],
    "additionalProperties": false,
  ]

  static let scriptedOutline: JSONValue = ["title": "Glass and Ash", "chapters": ["The Archive", "The Fog"], "tone": "cold"]

  static let script = DemoScript(
    rules: [
      DemoRule(DemoMatch(schema: "outline"), replies: [.json(scriptedOutline)]),
      DemoRule(DemoMatch(task: .chat, phrase: "villain"), replies: [.text("The Archivist lies.")]),
      DemoRule(DemoMatch(task: .chat), replies: [.text("Hello there, writer."), .text("Shall we begin?")]),
      DemoRule(DemoMatch(task: .writing), replies: []),
    ],
    fallback: "A demo answer.")

  static func request(_ text: String, format: ResponseFormat = .text) -> ModelRequest {
    ModelRequest(model: DemoModelProvider.model, system: [ContextSegment(text: "You help writers.")], messages: [.user(text)], maxOutputTokens: 500, format: format)
  }

  static func text(_ stream: ModelStream) async -> (text: String, events: [ModelEvent], error: ModelError?) {
    let (events, error) = await RoutingFixture.drain(stream)
    let text = events.compactMap { if case .textDelta(let delta) = $0 { delta } else { nil } }.joined()
    return (text, events, error)
  }

  static func router(
    script: DemoScript = script, limits: SpendLimits = .init(), credentials: StaticCredentials = StaticCredentials(credentials: [:]), store: VaultStore,
    clock: LedgerTestClock, assignments: OpenRouterAssignments = RoutingFixture.assignments
  ) -> TaskRouter {
    TaskRouter(
      configuration: RoutingFixture.configuration(.demo, assignments: assignments, limits: limits), demo: DemoModelProvider(script: script, pace: .zero),
      credentials: credentials, store: store, requestGuard: { _ in nil }, now: clock.function, calendar: RoutingFixture.utc)
  }
}

@Suite("DemoModelProvider", TestTimeLimit.quick)
struct DemoModelProviderTests {
  private let provider = DemoModelProvider(script: DemoFixture.script, pace: .zero)

  @Test("should stream the scripted text word by word, then finish at a reported cost of zero")
  func streamsScriptedText() async {
    let (text, events, error) = await DemoFixture.text(provider.answering(.chat).stream(DemoFixture.request("Hi")))

    #expect(error == nil)
    #expect(text == "Hello there, writer.")
    #expect(events.first == .started(requestID: nil, generationID: nil))
    #expect(events.dropFirst().dropLast() == [.textDelta("Hello"), .textDelta(" there,"), .textDelta(" writer.")])
    #expect(events.last == .finished(usage: .zero, reportedCost: .zero, stop: .endTurn))
  }

  @Test("should give a rule's replies in turn across every route's copy, starting again after the last")
  func rotatesReplies() async {
    var answers: [String] = []
    for _ in 0..<3 { answers.append(await DemoFixture.text(provider.answering(.chat).stream(DemoFixture.request("Hi"))).text) }

    #expect(answers == ["Hello there, writer.", "Shall we begin?", "Hello there, writer."])
  }

  @Test("should match on task and phrase in order, and answer an unmatched text call with the fallback")
  func matchesInOrder() {
    #expect(provider.answering(.chat).answer(DemoFixture.request("Who is the VILLAIN here?")) == "The Archivist lies.")
    #expect(provider.answering(.planning).answer(DemoFixture.request("Who is the villain?")) == "A demo answer.")
    #expect(provider.answering(.writing).answer(DemoFixture.request("Write chapter one.")) == "A demo answer.")
    #expect(provider.answer(DemoFixture.request("Hi")) == "A demo answer.")
  }

  @Test("should pause before each word after the first on its clock")
  func pacesWords() async {
    let clock = ManualClock(.manual)
    let paced = DemoModelProvider(script: DemoScript(fallback: "One two three"), pace: .milliseconds(25), clock: clock)
    let reading = Task { await DemoFixture.text(paced.stream(DemoFixture.request("Hi"))).text }
    for _ in 0..<2 {
      await clock.waitForSleepers()
      clock.advance(by: .milliseconds(25))
    }

    #expect(await reading.value == "One two three")
    #expect(clock.requestedSleeps == [Duration.milliseconds(25), .milliseconds(25)])
  }

  @Test("should refuse a request a real provider would refuse")
  func validatesRequest() async {
    let empty = ModelRequest(model: DemoModelProvider.model, system: [], messages: [], maxOutputTokens: 10)
    let (_, events, error) = await DemoFixture.text(provider.stream(empty))

    #expect(events.isEmpty)
    #expect(error?.code == "model.invalid_request")
  }

  @Test("should check no key and list only itself")
  func checksNoKey() async throws {
    await #expect(throws: ModelError.self) { try await provider.validate(try makeCredential()) }
    #expect(try await provider.models().map(\.id) == [DemoModelProvider.model])
  }

  @Test("should answer a native structured call with the scripted JSON")
  func answersNativeSchema() {
    let answer = provider.answer(DemoFixture.request("Outline it.", format: .json(name: "outline", schema: DemoFixture.outline)))

    #expect(answer == StructuredSchema.jsonText(DemoFixture.scriptedOutline))
  }

  @Test("should read the schema of a prompt-form call, also behind a repair re-ask")
  func readsPromptSchema() {
    let instructed = "Outline it.\n\n" + StructuredPrompt.schemaInstruction(name: "outline", schema: DemoFixture.outline)
    var request = DemoFixture.request(instructed)
    #expect(provider.answer(request) == StructuredSchema.jsonText(DemoFixture.scriptedOutline))

    request.messages += [.assistant("{}"), .user(StructuredPrompt.repairRequest(issues: [], previousOutput: "{}", schema: DemoFixture.outline))]
    #expect(provider.answer(request) == StructuredSchema.jsonText(DemoFixture.scriptedOutline))
  }

  @Test("should read an earlier instruction only behind a repair re-ask")
  func readsEarlierInstructionOnlyForRepair() {
    let instructed = "Outline it.\n\n" + StructuredPrompt.schemaInstruction(name: "outline", schema: DemoFixture.outline)
    var request = DemoFixture.request(instructed)
    request.messages += [.assistant("Here it is."), .user("Hi again")]

    #expect(provider.answering(.chat).answer(request) == "Hello there, writer.")
  }

  @Test("should answer with a sample the schema accepts when no reply fits it")
  func samplesUnscriptedSchema() throws {
    let wrong = DemoModelProvider(
      script: DemoScript(rules: [DemoRule(DemoMatch(schema: "outline"), replies: [.json(["title": "No"]), .text("Not JSON")])], fallback: "Demo"), pace: .zero)
    let unscripted = DemoFixture.request("Outline it.", format: .json(name: "summary", schema: DemoFixture.outline))
    let scriptedBadly = DemoFixture.request("Outline it.", format: .json(name: "outline", schema: DemoFixture.outline))

    for answer in [provider.answer(unscripted), wrong.answer(scriptedBadly), wrong.answer(scriptedBadly)] {
      #expect(StructuredSchema.validate(Data(answer.utf8), against: DemoFixture.outline).isEmpty)
    }
  }
}

@Suite("Demo routing", TestTimeLimit.quick)
struct DemoRoutingTests {
  private static func admitted(_ router: TaskRouter, _ call: TaskCall = RoutingFixture.call()) async -> Result<RoutedCall, TaskRouterError> {
    do throws(TaskRouterError) {
      return .success(try await router.prepare(call))
    } catch {
      return .failure(error)
    }
  }

  @Test("should route every standard task to the demo model with the catalog's cap and the prompt form", arguments: ModelTask.allCases)
  func routesToDemo(task: ModelTask) throws {
    let clock = LedgerTestClock()
    let route = try DemoFixture.router(store: try LedgerFixture.store(clock), clock: clock).route(task: task, pace: .meticulous, thinksDeeper: true)

    #expect(route.provider == .demo)
    #expect(route.model == DemoModelProvider.model)
    #expect(route.maxOutputTokens == 600)
    #expect(route.effort == nil && !route.deepened && !route.supportsNativeSchema)
  }

  @Test("should need no key, but still ask consent for the demo host")
  func gatesOnConsentOnly() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    let router = DemoFixture.router(store: store, clock: clock)

    guard case .failure(.consentRequired(let request)) = await Self.admitted(router) else {
      Issue.record("expected consentRequired")
      return
    }
    #expect(request == AIConsentRequest(provider: .demo, host: DemoModelProvider.host, dataClass: "novel", disclosure: "novel-text/v1"))
    #expect(try await router.missingConsent(RoutingFixture.consent) == request)

    try await RoutingFixture.grantConsent(host: request.host, in: store)
    guard case .success(let call) = await Self.admitted(router) else {
      Issue.record("expected the call to be admitted")
      return
    }
    #expect(call.host == DemoModelProvider.host)
    #expect(try await router.missingConsent(RoutingFixture.consent) == nil)
  }

  @Test("should refuse unrestricted calls, which never reach the demo")
  func refusesUnrestricted() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: DemoModelProvider.host, in: store)

    let assigned = await Self.admitted(DemoFixture.router(store: store, clock: clock), RoutingFixture.call(mode: .unrestricted))
    let unassigned = await Self.admitted(
      DemoFixture.router(store: store, clock: clock, assignments: OpenRouterAssignments()), RoutingFixture.call(mode: .unrestricted))

    guard case .failure(.providerMissing(.openRouter)) = assigned, case .failure(.unrestrictedModelMissing) = unassigned else {
      Issue.record("expected unrestricted calls to be refused")
      return
    }
  }

  @Test("should ledger a demo call at a reported cost of zero, labelled as a demo, past any spend cap")
  func ledgersAtZeroCost() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: DemoModelProvider.host, in: store)
    try await LedgerFixture.open(
      LedgerFixture.entry(startedMillis: clock.millis, outcome: .finished, cost: Cost(nanoUSD: 5 * Cost.nanoUSDPerUSD), costSource: .computed), in: store)
    let router = DemoFixture.router(limits: SpendLimits(daily: Cost(nanoUSD: 1), monthly: Cost(nanoUSD: 1)), store: store, clock: clock)
    #expect(try await router.spendDecision() == .allowed)

    let call = try await router.prepare(RoutingFixture.call())
    let (text, _, error) = await DemoFixture.text(call.provider.stream(call.request(system: [], messages: [.user("Hi")])))
    await call.settled()

    #expect(error == nil && text == "Hello there, writer.")
    let entry = try #require(try await LedgerFixture.entries(store).first(where: \.isDemo))
    #expect(entry.provider == DemoModelProvider.host && entry.model == DemoModelProvider.model && entry.task == .chat)
    #expect(entry.outcome == .finished && entry.cost == .zero && entry.costSource == .reported)
    #expect(call.callIDs == [entry.id])
  }

  @Test("should answer a routed structured call with JSON that passes the full schema in the prompt form")
  func answersStructuredCall() async throws {
    let clock = LedgerTestClock()
    let store = try LedgerFixture.store(clock)
    try await RoutingFixture.grantConsent(host: DemoModelProvider.host, in: store)
    let call = try await DemoFixture.router(store: store, clock: clock).prepare(RoutingFixture.call(.planning))

    let result = try await call.structured(call.request(system: [], messages: [.user("Outline the novel.")]), name: "outline", schema: DemoFixture.outline)
    let unscripted = try await call.structured(call.request(system: [], messages: [.user("Sum it up.")]), name: "summary", schema: DemoFixture.outline)

    #expect(result.mode == .prompt && !result.wasRepaired)
    #expect(try CanonicalJSON.decode(result.json, mode: .lenient) == DemoFixture.scriptedOutline)
    #expect(!unscripted.wasRepaired)
    #expect(StructuredSchema.validate(unscripted.json, against: DemoFixture.outline).isEmpty)
  }
}
