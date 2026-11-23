import Foundation
import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import Memoir

nonisolated private struct AskCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: AskWorld.origin, secret: "sk-test")
  }
}

/// The spend limits the router reads on each call, changed by a test while the model runs.
nonisolated final class AskLimits: Sendable {
  private let current: Mutex<SpendLimits>

  init(_ limits: SpendLimits) {
    current = Mutex(limits)
  }

  var value: SpendLimits {
    get { current.withLock { $0 } }
    set { current.withLock { $0 = newValue } }
  }
}

/// A vault in UTC on a hand-moved clock whose insights call a scripted provider at a test host, with consent read and withdrawn for that host.
@MainActor
struct AskWorld {
  nonisolated static let origin = URL(string: "https://api.example.com")!
  nonisolated static let host = "api.example.com"
  nonisolated static let journalText = "I skipped the evening run because my manager kept me on a call until nearly nine"

  let clock: TestClock
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  let provider = ScriptedModelProvider()
  let access: InsightAccess
  let providerReady: Flag
  let settlements = Recorded<Int>()
  let limits: AskLimits

  init(limits: SpendLimits = SpendLimits(), providerReady ready: Bool = true) async throws {
    let clock = TestClock(day: 0, minute: 360)
    let waitUntil: @Sendable (Date) async throws -> Void = { deadline in
      while clock.now() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }
    let opened = try await MemoirVaultOpener.open(
      .inMemory, appVersion: "1", clock: MemoirClock(now: clock.now, deviceZone: { TestClock.utc }, waitUntil: waitUntil))
    let context = MemoirScreenContext(opened)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    let providerReady = Flag()
    if ready { providerReady.set() }
    self.clock = clock
    self.opened = opened
    self.context = context
    self.providerReady = providerReady
    let limits = AskLimits(limits)
    self.limits = limits
    let settlements = settlements
    let settler = CostSettler(cooldown: .zero) { () async throws(StoreError) -> ReconciliationReport in
      settlements.append(1)
      throw StoreError.database("the test settles nothing")
    }
    access = Self.access(opened: opened, provider: provider, limits: limits, providerReady: providerReady, settler: settler)
  }

  static func access(opened: MemoirOpenedVault, provider: ScriptedModelProvider, limits: AskLimits, providerReady: Flag, settler: CostSettler?) -> InsightAccess {
    let main = opened.stores.main
    let leases = LeaseClock(trusted: nil, device: opened.clock.now)
    let router: InsightEngine.RouterSource = {
      TaskRouter(
        configuration: TaskRouterConfiguration(provider: .anthropic, spendLimits: limits.value), anthropic: ProviderBinding(origin: origin, provider: provider),
        credentials: AskCredentials(), store: main, requestGuard: { _ in nil }, now: opened.clock.now)
    }
    let engine = InsightEngine(
      stores: opened.stores, replay: ProjectionInsightReplay(main: main, now: opened.clock.now, deviceZone: opened.clock.deviceZone), router: router, clock: leases)
    return InsightAccess(engine: engine, router: router, isProviderReady: { providerReady.isSet }, leases: leases, settler: settler)
  }

  var consents: InsightConsents {
    let main = context.stores.main
    return InsightConsents(
      granted: {
        try await main.read { transaction in
          Set(
            try AskConsentKind.allCases.map(\.requirement).filter { requirement in
              try AIConsent.isGranted(provider: Self.host, dataClass: requirement.dataClass, currentSummary: requirement.disclosure, in: transaction)
            }.map(\.dataClass))
        }
      },
      withdraw: { dataClass in
        let requirement = try #require(AskConsentKind.allCases.map(\.requirement).first { $0.dataClass == dataClass })
        try await main.write { transaction in
          try AIConsent.decide(.revoked, provider: Self.host, dataClass: dataClass, summary: requirement.disclosure, atMillis: 2, in: &transaction)
        }
      })
  }

  func model() -> AskModel {
    AskModel(context: context, access: access, consents: consents)
  }

  /// What the consent sheet writes when the owner allows `request`.
  func allow(_ request: AIConsentRequest) async throws {
    try await context.stores.main.write { transaction in
      try AIConsent.decide(.granted, provider: request.host, dataClass: request.dataClass, summary: request.disclosure, atMillis: 1, in: &transaction)
    }
  }

  func grant(_ kinds: [AskConsentKind]) async throws {
    for kind in kinds {
      try await allow(AIConsentRequest(provider: .anthropic, host: Self.host, dataClass: kind.requirement.dataClass, disclosure: kind.requirement.disclosure))
    }
  }

  func seedJournal() async throws {
    _ = try await context.stores.main.write { transaction in
      try JournalEntryRecord(id: UUID.v7(), date: TestClock.day(0), text: Self.journalText, mood: 2, loggedAtMillis: 1).create(in: &transaction)
    }
  }

  static func reply(answer: String = "Evening quests slip on late work days.", suggestions: String = "") -> String {
    #"{"answer":"\#(answer)","patterns":["Misses cluster after 20:00."],"suggestions":[\#(suggestions)],"limitationNote":null}"#
  }

  var prompts: [String] { provider.requests.map { $0.messages.map(\.text).joined(separator: "\n") } }

  func commandCount() async throws -> Int {
    try await context.stores.commands().count
  }
}

@MainActor
@Suite("AskModel", TestTimeLimit.standard)
struct AskModelTests {
  private static let question = "Why do I keep missing evening quests?"

  private func running(_ world: AskWorld) async throws -> (AskModel, Task<Void, Never>) {
    let model = world.model()
    let task = Task { await model.run() }
    try await until("the board") { model.board.value != nil && model.setup != .checking }
    return (model, task)
  }

  /// The answers are stored a moment before their attempts settle, so a test waits for both.
  private func answered(_ model: AskModel, _ count: Int, _ what: String) async throws {
    try await until(what) { model.board.value?.results.count == count && model.board.value?.requests.allSatisfy { $0.status == .succeeded } == true }
  }

  private func ask(_ model: AskModel, _ question: String = question) async {
    model.question = question
    await model.submit()
  }

  @Test("should hold a question for the call's consent, then ask it under the same id once allowed, issuing no command")
  func holdsForTheCallConsent() async throws {
    let world = try await AskWorld()
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let commands = try await world.commandCount()
    #expect(model.setup == .ready(granted: []))

    await ask(model)

    let prompt = try #require(model.consentPrompt)
    #expect(prompt.dataClass == InsightConsent.call.dataClass && prompt.host == AskWorld.host)
    #expect(model.board.value?.requests.isEmpty == true)
    #expect(world.provider.requests.isEmpty)

    world.provider.enqueueReply(AskWorld.reply())
    try await world.allow(prompt)
    model.consentPrompt = nil
    await model.consentAllowed()

    try await answered(model, 1, "the answer")
    let board = try #require(model.board.value)
    #expect(board.requests.map(\.status) == [.succeeded])
    #expect(board.results.first?.answer == "Evening quests slip on late work days.")
    #expect(board.request(for: try #require(board.results.first))?.question == Self.question)
    #expect(model.question.isEmpty)
    #expect(model.setup.granted == [.call])
    #expect(world.provider.requests.count == 1)
    #expect(try await world.commandCount() == commands, "the insight path issues no command")
    try await until("the attempt's calls priced") { !world.settlements.values.isEmpty }
  }

  @Test("should send journal text only while its own consent is granted")
  func gatesJournalText() async throws {
    let world = try await AskWorld()
    try await world.seedJournal()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }

    world.provider.enqueueReply(AskWorld.reply())
    await ask(model, "First question")
    try await answered(model, 1, "the first answer")
    #expect(world.prompts.last?.contains(AskWorld.journalText) == false)

    await model.requestConsent(.journal)
    let prompt = try #require(model.consentPrompt)
    #expect(prompt.dataClass == InsightConsent.requirement(for: .journalReflectionReason).dataClass)
    try await world.allow(prompt)
    model.consentPrompt = nil
    await model.consentAllowed()
    #expect(model.setup.granted == [.call, .journal])

    world.provider.enqueueReply(AskWorld.reply())
    await ask(model, "Second question")
    try await answered(model, 2, "the second answer")
    #expect(world.prompts.last?.contains(AskWorld.journalText) == true)

    await model.withdraw(.journal)
    #expect(model.setup.granted == [.call])
    world.provider.enqueueReply(AskWorld.reply())
    await ask(model, "Third question")
    try await answered(model, 3, "the third answer")
    #expect(world.prompts.last?.contains(AskWorld.journalText) == false)
  }

  @Test("should cancel a running question, then ask it again")
  func cancelsAndRetries() async throws {
    let world = try await AskWorld()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    world.provider.enqueue([.delay(.seconds(60))] + ScriptedModelProvider.reply(AskWorld.reply()))

    await ask(model)
    try await until("the running question with its call taken by the provider") {
      model.board.value?.active?.status == .running && world.provider.requests.count == 1
    }
    let running = try #require(model.board.value?.active)

    await model.cancel(running)
    try await until("the cancelled question") { model.board.value?.requests.first?.status == .cancelled }
    #expect(model.board.value?.results.isEmpty == true)

    world.provider.enqueueReply(AskWorld.reply())
    let cancelled = try #require(model.board.value?.requests.first)
    await model.retry(cancelled)
    try await answered(model, 1, "the answer")
    #expect(model.board.value?.requests.map(\.run) == [2])
    #expect(model.board.value?.active == nil)
    #expect(world.provider.requests.count == 2)
  }

  @Test("should read again when the running question's lease lapses, then let a new question be asked and ask the lapsed one again")
  func asksPastALapsedLease() async throws {
    let world = try await AskWorld()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    world.provider.enqueue([.delay(.seconds(60))] + ScriptedModelProvider.reply(AskWorld.reply()))

    await ask(model)
    try await until("the running question with its call begun") { model.board.value?.active.map { $0.status == .running && $0.cost.pendingCalls == 1 } == true }
    model.question = "Another question"
    #expect(!model.canSubmit, "one question runs at a time")

    let raised = SpendLimits(daily: Cost(nanoUSD: 7_000_000_000))
    world.limits.value = raised
    world.clock.set(day: 0, minute: 400)
    try await until("the lapsed lease, read again with no write and priced under the raised limit") {
      model.board.value?.active?.status == .queued && model.spend?.limits == raised
    }
    #expect(model.canSubmit, "a queued request whose lease lapsed does not block asking")

    let lapsed = try #require(model.board.value?.active)
    await model.retry(lapsed)
    #expect(model.notice == .alreadyRunning, "its attempt still runs on this device")
    await model.cancel(lapsed)
    try await until("the cancelled question") { model.board.value?.requests.first?.status == .cancelled }
  }

  @Test("should show a blocked answer as failed and ask it again on retry")
  func retriesAFailure() async throws {
    let world = try await AskWorld()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    let commands = try await world.commandCount()
    world.provider.enqueueReply(AskWorld.reply(answer: "You are lazy about evenings."))

    await ask(model)
    try await until("the failure") { model.board.value?.active?.status == .failed(code: "insight.guardrail_blocked") }
    #expect(model.board.value?.results.isEmpty == true)
    #expect(model.canSubmit == false, "an empty question cannot be asked")

    world.provider.enqueueReply(AskWorld.reply())
    await model.retry(try #require(model.board.value?.active))
    try await answered(model, 1, "the answer")
    #expect(model.board.value?.active == nil)
    #expect(try await world.commandCount() == commands)
  }

  @Test("should wait at the spend cap without asking")
  func waitsAtTheSpendCap() async throws {
    let world = try await AskWorld(limits: SpendLimits(daily: Cost.zero))
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    #expect(model.spend?.decision == .dailyLimitReached(spent: .zero, limit: .zero))

    await ask(model)

    #expect(model.notice == .waitingForSpend(.dailyLimitReached(spent: .zero, limit: .zero)))
    #expect(model.board.value?.requests.isEmpty == true)
    #expect(world.provider.requests.isEmpty)
    #expect(model.question == Self.question, "the question stays for a later try")
  }

  @Test("should offer the provider connection and ask nothing without a key")
  func needsAProvider() async throws {
    let world = try await AskWorld(providerReady: false)
    let (model, task) = try await running(world)
    defer { task.cancel() }
    #expect(model.setup == .noProvider)
    model.question = Self.question
    #expect(!model.canSubmit)
    await model.submit()
    #expect(world.provider.requests.isEmpty && model.consentPrompt == nil)

    world.providerReady.set()
    await model.refreshSetup()
    #expect(model.setup == .ready(granted: []))
    #expect(model.canSubmit)
  }

  @Test("should hold the Ask screen and the nightly question while OpenRouter has a key but no model for any pace, and go on once one pace has a model")
  func shouldWaitForAnOpenRouterModel() async throws {
    let suite = "com.shadow.apps.memoir.tests.ask-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let ai = AIServices(
      identity: .memoir, keys: .standard(store: InMemorySecureStore()), settingsStore: AISettingsStore(identity: .memoir, defaults: defaults),
      transport: StubHTTPExchangeTransport(), disclosures: ConsentDisclosure.memoir, requestGuard: { _ in nil })
    try ai.saveKey(try #require(ai.keys.makeCredential("sk-or-test", for: .openRouter)), for: .openRouter)
    ai.update { $0.provider = .openRouter }
    let world = try await AskWorld()
    try await world.grant([.call])
    let live = MemoirInsights.access(stores: world.opened.stores, clock: world.opened.clock, ai: ai, trustedClock: nil)
    let access = InsightAccess(
      engine: world.access.engine, router: world.access.router, isProviderReady: live.isProviderReady, leases: world.access.leases, settler: world.access.settler)
    let model = AskModel(context: world.context, access: access, consents: world.consents)
    let task = Task { await model.run() }
    defer { task.cancel() }
    try await until("the board") { model.board.value != nil && model.setup != .checking }
    #expect(ai.hasUsableProvider)
    #expect(model.setup == .noProvider)
    await model.setSchedule(question: "How did this week go?", minuteOfDay: 120)
    try await until("the schedule") { model.board.value?.schedule != nil }
    world.clock.set(day: 1, minute: 130)

    await MemoirInsights.runForeground(access: access, vault: world.opened, resume: false)
    #expect(world.provider.requests.isEmpty)
    #expect(model.board.value?.requests.isEmpty == true)

    ai.update { $0.assignments.models[Pace.allCases[0]] = "vendor/model" }
    await model.refreshSetup()
    #expect(model.setup == .ready(granted: [.call]))
    world.provider.enqueueReply(AskWorld.reply())
    await MemoirInsights.runForeground(access: access, vault: world.opened, resume: false)
    try await answered(model, 1, "the night's answer")
    #expect(model.board.value?.requests.first?.kind == .scheduled)
  }

  @Test("should accept a question of 1 to 2,000 characters counted as the reference counts them")
  func boundsTheQuestion() async throws {
    let world = try await AskWorld()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    for (text, allowed) in [("", false), ("   ", false), ("?", true), (String(repeating: "é", count: 2_000), true), (String(repeating: "a", count: 2_001), false)] {
      model.question = text
      #expect(model.canSubmit == allowed, "\(text.unicodeScalars.count) characters")
    }
  }

  @Test("should run the standing question's due night only once the app is in the foreground")
  func runsTheNightAtForeground() async throws {
    let world = try await AskWorld()
    try await world.grant([.call])
    let (model, task) = try await running(world)
    defer { task.cancel() }
    await model.setSchedule(question: "  How did this week go?  ", minuteOfDay: 120)
    try await until("the schedule") { model.board.value?.schedule?.question == "How did this week go?" }
    let commands = try await world.commandCount()

    let insights = MemoirInsights { _ in world.access }
    world.clock.set(day: 1, minute: 130)
    world.provider.enqueueReply(AskWorld.reply())
    await insights.follow(world.opened)
    #expect(world.provider.requests.isEmpty, "nothing runs in the background")
    try await until("the leftovers priced on follow") { world.settlements.values.count == 1 }

    await insights.phaseChanged(isActive: true)

    try await answered(model, 1, "the night's answer")
    let request = try #require(model.board.value?.requests.first)
    #expect(request.kind == .scheduled && request.target == .night(TestClock.day(1)))
    #expect(try await world.commandCount() == commands)

    try await until("the night's calls priced after the run") { world.settlements.values.count >= 2 }
    await insights.phaseChanged(isActive: true)
    #expect(world.provider.requests.count == 1, "a night runs once")

    await model.clearSchedule()
    try await until("the schedule off") { model.board.value?.schedule?.active == false }
  }

  @Test("should link each suggestion to the screen where the owner makes the change")
  func linksSuggestions() {
    let quest = UUID()
    let link = { (kind: InsightSuggestionKind) in AskSuggestionLink.route(for: InsightSuggestion(kind: .known(kind), quest: quest, text: "")) }
    #expect(link(.shiftTime) == .quest(.edit(quest)))
    #expect(link(.adjustReminder) == .quest(.edit(quest)))
    #expect(link(.splitQuest) == .quest(.duplicate(quest)))
    #expect(link(.pauseQuest) == .quest(.detail(quest)))
  }
}
