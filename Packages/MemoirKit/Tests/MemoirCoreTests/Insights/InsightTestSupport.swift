import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization

@testable import MemoirCore
@testable import ShadowJobs

struct InsightCredentials: ModelCredentialSource {
  let origin: URL

  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: origin, secret: "sk-test")
  }
}

/// Hands out the queued routers one per call, then the standing one.
final class RouterQueue: Sendable {
  private let standing: TaskRouter
  private let queued = Mutex<[TaskRouter]>([])

  init(_ standing: TaskRouter) {
    self.standing = standing
  }

  func enqueue(_ routers: [TaskRouter]) {
    queued.withLock { $0 += routers }
  }

  func next() -> TaskRouter {
    queued.withLock { $0.isEmpty ? standing : $0.removeFirst() }
  }
}

/// Crashes the runner once, at `point`.
func crashing(once point: AttemptRunner.Faults.Point) -> AttemptRunner.Faults {
  let fired = Mutex(false)
  return AttemptRunner.Faults { candidate in
    candidate == point
      && fired.withLock { fired in
        defer { fired = true }
        return !fired
      }
  }
}

/// A replay that returns a fixed state and records how it was asked; `onRead` runs before it answers.
final class StubReplay: InsightReplaySource {
  private let state: InsightReplayState
  private let onRead: @Sendable (Bool) async -> Void
  private let asked = Mutex<[Bool]>([])

  init(
    _ state: InsightReplayState = InsightReplayState(profile: InsightProfile(timeZone: "Europe/London", intensityMode: .standard)),
    onRead: @escaping @Sendable (Bool) async -> Void = { _ in }
  ) {
    self.state = state
    self.onRead = onRead
  }

  var includingText: [Bool] { asked.withLock { $0 } }

  func insightState(includingText: Bool) async throws(InsightError) -> InsightReplayState {
    asked.withLock { $0.append(includingText) }
    await onRead(includingText)
    return state
  }
}

struct InsightHarness {
  static let origin: URL = {
    guard let url = URL(string: "https://api.example.com") else { preconditionFailure("a valid origin") }
    return url
  }()
  static let host = "api.example.com"
  static let quest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000c1")
  static let otherQuest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000c2")
  static let healthMetric = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000000d1")
  static let journalText = "I skipped the evening run because my manager kept me on a call until nearly nine"
  static let reasonNote = "too tired after the late standup meeting"

  static func day(_ text: String, plus days: Int = 0) -> LocalDate {
    guard let date = LocalDate(isoString: text)?.adding(days: days) else { preconditionFailure("\(text) plus \(days) days is a date") }
    return date
  }

  static let otherOrigin: URL = {
    guard let url = URL(string: "https://other.example.com") else { preconditionFailure("a valid origin") }
    return url
  }()

  let stores: MemoirStores
  let provider: ScriptedModelProvider
  let replay: StubReplay
  let routers: RouterQueue
  let clock: MemoirTestClock
  let budget: Int
  let engine: InsightEngine

  init(
    replay: StubReplay = StubReplay(), budget: Int = InsightAssembler.defaultBudget, limits: SpendLimits = .init(), faults: AttemptRunner.Faults = .none
  ) throws {
    let stores = try MemoirStores.openInMemory()
    let provider = ScriptedModelProvider()
    let routers = RouterQueue(Self.router(Self.origin, provider: provider, store: stores.main, limits: limits))
    self.stores = stores
    self.provider = provider
    self.replay = replay
    self.routers = routers
    self.budget = budget
    clock = MemoirTestClock()
    engine = Self.engine(stores: stores, replay: replay, routers: routers, clock: clock, budget: budget, faults: faults)
  }

  static func router(_ origin: URL, provider: ScriptedModelProvider, store: VaultStore, limits: SpendLimits = .init()) -> TaskRouter {
    TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic, spendLimits: limits), anthropic: ProviderBinding(origin: origin, provider: provider),
      credentials: InsightCredentials(origin: origin), store: store, requestGuard: { _ in nil })
  }

  private static func engine(
    stores: MemoirStores, replay: StubReplay, routers: RouterQueue, clock: MemoirTestClock, budget: Int, faults: AttemptRunner.Faults
  ) -> InsightEngine {
    let leases = LeaseClock(trusted: nil, device: clock.function)
    let runner = AttemptRunner(store: stores.main, clock: leases, timing: .standard, faults: faults)
    return InsightEngine(stores: stores, replay: replay, router: { routers.next() }, clock: leases, runner: runner, pace: .steady, budget: budget)
  }

  /// Another process on the same vault, after this one ended.
  func relaunched() -> InsightEngine {
    clock.advance(seconds: 5)
    return Self.engine(stores: stores, replay: replay, routers: routers, clock: clock, budget: budget, faults: .none)
  }

  func grant(_ classes: [InsightDataClass] = [], call: Bool = true) async throws {
    try await stores.main.write { transaction in
      if call {
        try AIConsent.decide(
          .granted, provider: Self.host, dataClass: InsightConsent.call.dataClass, summary: InsightConsent.call.disclosure, atMillis: 1, in: &transaction)
      }
      for dataClass in classes { try InsightConsent.decide(.granted, dataClass, provider: Self.host, atMillis: 1, in: &transaction) }
    }
  }

  func revoke(_ dataClass: InsightDataClass) async throws {
    try await stores.main.write { transaction in try InsightConsent.decide(.revoked, dataClass, provider: Self.host, atMillis: 2, in: &transaction) }
  }

  /// A quest, a journal entry, a weight, a health metric's day, a step count and a general metric.
  func seed() async throws {
    let date = try MemoirStoreFixture.date("2026-11-20")
    try await stores.main.write { transaction in
      try QuestRecord(id: Self.quest, name: "Evening run").create(in: &transaction)
      try QuestRecord(id: Self.otherQuest, name: "Morning pages").create(in: &transaction)
      try JournalEntryRecord(id: MemoirStoreFixture.commandID(1), date: date, text: Self.journalText, mood: 2, loggedAtMillis: 1).create(in: &transaction)
      let pages = MetricID<GeneralMetric>(recordUUID: MemoirStoreFixture.commandID(2))
      try MetricRecord(id: pages, name: "Pages read", unit: "pages", valueType: .known(.count), direction: .known(.higher)).create(in: &transaction)
      try MetricDayRecord(metric: pages, date: date, entry: MetricEntry(value: try MemoirStoreFixture.decimal("31"))).create(in: &transaction)
    }
    try await stores.activity.write { transaction in
      let steps = BuiltinMetric.steps.reference
      let id = MetricID<ActivityMetric>(recordUUID: steps.id)
      try MetricRecord(id: id, name: "Steps", unit: "steps", valueType: .known(.count), direction: .known(.higher)).create(in: &transaction)
      try MetricDayRecord(metric: id, date: date, imported: try MemoirStoreFixture.decimal("8123")).create(in: &transaction)
    }
    try await stores.restricted.write { transaction in
      try WeightRecord(date: date, kilograms: try MemoirStoreFixture.decimal("72.4"), loggedAtMillis: 1).create(in: &transaction)
      let heart = MetricID<HealthMetric>(recordUUID: Self.healthMetric)
      try MetricRecord(id: heart, name: "Resting heart rate", unit: "bpm", valueType: .known(.number), direction: .known(.lower)).create(in: &transaction)
      try MetricDayRecord(metric: heart, date: date, entry: MetricEntry(value: try MemoirStoreFixture.decimal("61"))).create(in: &transaction)
    }
  }

  static func replayState(reasonNote: String? = reasonNote) throws -> InsightReplayState {
    let date = try MemoirStoreFixture.date("2026-11-20")
    return InsightReplayState(
      profile: InsightProfile(timeZone: "Europe/London", intensityMode: .standard),
      quests: [InsightQuestState(quest: quest, startTimeMinutes: 1140, durationMinutes: 30, statAffinity: .body, strictness: .routine)],
      questLogs: [InsightQuestLog(quest: quest, date: date, state: .missed, strictness: .routine, intensityModeAtLog: .standard, reasonNote: reasonNote)],
      dailyStates: [InsightDailyState(date: date, intensityMode: .standard, hpStart: 100, hpEnd: 95, hpMax: 100)],
      progressionEvents: [.title(id: "early_bird", earnedAtMillis: 1_763_600_000_000)])
  }

  static func reply(answer: String = "Evening quests slip on late work days.", suggestions: [[String: String]] = [], note: String? = nil) -> String {
    let encoded = suggestions.map { suggestion in
      "{" + suggestion.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",") + "}"
    }
    let limitation = note.map { "\"\($0)\"" } ?? "null"
    return #"{"answer":"\#(answer)","patterns":["Misses cluster after 20:00."],"suggestions":[\#(encoded.joined(separator: ","))],"limitationNote":\#(limitation)}"#
  }

  var sentPrompts: [String] { provider.requests.map { $0.messages.map(\.text).joined(separator: "\n") } }

  func results() async throws -> [InsightResultEntry] {
    try await InsightResults.listing(in: stores)
  }

  func snapshot(_ job: EntityRef) async throws -> JobSnapshot? {
    try await stores.main.read { transaction in try JobSnapshot.load(job, in: transaction) }
  }

  func commandCount() async throws -> Int {
    try await stores.main.read { transaction in try transaction.states(ofKind: MemoirKind.command.entityKind, scope: .vault).count }
  }
}

extension InsightDue {
  var handle: AttemptHandle? {
    guard case .started(let handle) = self else { return nil }
    return handle
  }

  var label: String {
    switch self {
    case .notScheduled: "notScheduled"
    case .waitingForConsent: "waitingForConsent"
    case .waitingForSpend: "waitingForSpend"
    case .started: "started"
    case .running: "running"
    case .succeeded: "succeeded"
    case .cancelled: "cancelled"
    case .failed(_, let code): "failed:\(code)"
    }
  }
}
