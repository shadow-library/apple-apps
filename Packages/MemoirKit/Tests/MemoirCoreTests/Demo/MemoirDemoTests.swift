import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowText
import Testing

@testable import MemoirCore

@Suite("Memoir demo", TestTimeLimit.standard)
struct MemoirDemoTests {
  private static let zone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
  private static let now = Date(timeIntervalSince1970: 1_795_000_000)
  private static let euro = CurrencyCode("EUR")!
  private static let quests = [MemoirDemo.walk, MemoirDemo.lines, MemoirDemo.reading, MemoirDemo.stretch, MemoirDemo.budget]

  private static var today: LocalDate {
    get throws { try IssueClock(timeZone: zone).localDate(at: Int64(now.timeIntervalSince1970 * 1000)) }
  }

  private static func seeded() async throws -> MemoirStores {
    let reconciler = try MemoirReconciler(appVersion: "1", now: { now }, deviceZone: { zone })
    let stores = try MemoirStores.openInMemory(wallClock: { now }, projection: reconciler)
    try await MemoirDemo.seed(stores, now: now, zone: zone, currency: euro)
    try await reconciler.refresh(stores.main)
    return stores
  }

  @Test("should seed a week that Today, Hero, Money, Reflect and the journal all show, with today's quests still open")
  func shouldSeedAWeekTheReadsShow() async throws {
    let stores = try await Self.seeded()
    let today = try Self.today

    let board = try await stores.main.load(TodayBoard.self, TodayBoardQuery(date: today))
    #expect(board.openDay == today)
    #expect(Set(board.occurrences.map(\.quest.id)).isSuperset(of: [MemoirDemo.walk, MemoirDemo.lines, MemoirDemo.reading]))
    let hero = try #require(try await stores.main.read { transaction in try MemoirDerived.hero(in: transaction) })
    #expect(hero.totalXP > 0)
    #expect(hero.zone.inForce == Self.zone.identifier)
    #expect(hero.questsCompleted > 15)
    #expect(hero.halt == nil)

    let (book, budgets) = try await stores.main.read { transaction in (try MoneyBook.load(from: transaction), try BudgetBook.load(from: transaction)) }
    #expect(book.expenses.count == 6)
    #expect(book.settings?.defaultCurrency == Self.euro)
    let overview = try #require(try MoneyOverview.make(book, budgets: budgets, today: today))
    #expect(overview.spend(.month).spentSoFarMinor > 0 || overview.spend(.week).spentSoFarMinor > 0)

    let history = try await ReflectReads.history(in: stores, matching: HistoryQuery(page: .all), bodyClasses: [], today: today)
    #expect(history.totalRecords > 20)
    let insights = try await ReflectReads.insights(in: stores, period: .thirtyDays, bodyClasses: [], today: today)
    #expect(insights.kept.occurrences > 0 && insights.kept.percent.map { $0 > 0 } == true)
    #expect(try await LogReads.journal(in: stores, today: today).entries.count == 2)
  }

  @Test("should leave a vault that is already set up as it is")
  func shouldLeaveASetUpVaultAlone() async throws {
    let stores = try await Self.seeded()
    let count = try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries.count }

    try await MemoirDemo.seed(stores, now: Self.now, zone: Self.zone, currency: Self.euro)

    #expect(try await MemoirDemo.isSeeded(stores))
    #expect(try await stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries.count } == count)
  }

  @Test("should script insight replies the insight schema accepts and the guardrails pass whole")
  func shouldScriptInsightRepliesTheSchemaAccepts() throws {
    for reply in MemoirDemo.insightReplies {
      let text = CanonicalJSON.encode(reply)
      #expect(StructuredSchema.validate(text, against: InsightPrompt.schema).isEmpty)
      let draft = try InsightDraft(parsing: try OrderedJSON(parsing: String(decoding: text, as: UTF8.self)))
      #expect(!draft.suggestions.isEmpty)
      let input = GuardrailInput(
        question: "How was my week?", sensitiveSources: [], allowedQuestIDs: Self.quests.map { $0.uuidString.lowercased() }, draft: draft)
      #expect(InsightGuardrails.apply(input) == .passed(draft))
    }
  }

  @Test("should answer a question in the demo with a result naming a seeded quest")
  func shouldAnswerAQuestionInTheDemo() async throws {
    let stores = try await Self.seeded()
    try await stores.main.write { transaction in
      try AIConsent.decide(
        .granted, provider: DemoModelProvider.host, dataClass: InsightConsent.call.dataClass, summary: InsightConsent.call.disclosure, atMillis: 1, in: &transaction)
    }
    let demo = DemoModelProvider(script: DemoScript(rules: MemoirDemo.insightRules, fallback: MemoirDemo.fallback), pace: .zero)
    let main = stores.main
    let router = TaskRouter(
      configuration: TaskRouterConfiguration(provider: .demo), demo: demo, credentials: NoCredentials(), store: main, requestGuard: { _ in nil })
    let engine = InsightEngine(
      stores: stores, replay: ProjectionInsightReplay(main: main, now: { Self.now }, deviceZone: { Self.zone }), router: { router },
      clock: LeaseClock(trusted: nil, device: { Self.now }))

    guard case .started(let handle) = try await engine.ask("How was my week?", id: UUID()) else {
      Issue.record("the question did not start")
      return
    }

    #expect(await handle.result == .settled(.succeeded))
    let result = try #require(try await InsightResults.listing(in: stores).first)
    #expect(result.answer == MemoirDemo.insightReplies.first?["answer"]?.stringValue)
    #expect(result.suggestions.map(\.quest) == [MemoirDemo.reading])
  }
}

private struct NoCredentials: ModelCredentialSource {
  func credential(for provider: ModelProviderKind) async -> ProviderCredential? { nil }
}
