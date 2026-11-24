import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import MemoirCore

@Suite("Insight read assembly", TestTimeLimit.quick)
struct InsightAssemblyTests {
  private static let question = "why do I keep missing evening quests?"
  private static let today = InsightHarness.day("2026-11-21")

  private func prompt(_ assembly: InsightAssembly) -> String {
    InsightPrompt.user(question: Self.question, context: assembly.context)
  }

  private func assemble(_ consent: InsightConsentSnapshot, replay: StubReplay? = nil, budget: Int = InsightAssembler.defaultBudget) async throws -> (
    InsightAssembly, StubReplay
  ) {
    let replay = try replay ?? StubReplay(InsightHarness.replayState())
    let harness = try InsightHarness(replay: replay)
    try await harness.seed()
    let assembler = InsightAssembler(stores: harness.stores, replay: replay, budget: budget)
    return (try await assembler.assemble(question: Self.question, consent: consent, today: Self.today), replay)
  }

  @Test func shouldLeaveJournalReasonAndHealthDataOutOfThePromptWithoutConsent() async throws {
    let (assembly, replay) = try await assemble(.none)
    let text = prompt(assembly)
    for secret in [InsightHarness.journalText, InsightHarness.reasonNote, "72.4", "kg", "Resting heart rate", "Steps", "8123", "reasonNote", "reflectionText"] {
      #expect(!text.contains(secret), "\(secret) reached the prompt without consent")
    }
    #expect(text.contains("Evening run"))
    #expect(text.contains("Pages read"))
    #expect(text.contains(#""journal":[]"#))
    #expect(text.contains(#""health":[]"#))
    #expect(replay.includingText == [false])
    #expect(assembly.sensitiveSources.isEmpty)
    #expect(!assembly.dataClasses.contains(.journalReflectionReason))
    #expect(!assembly.dataClasses.contains(.health))
    #expect(assembly.resultClass == .general)
  }

  @Test func shouldIncludeTheJournalClassOnlyWithItsOwnConsent() async throws {
    let (assembly, replay) = try await assemble(InsightConsentSnapshot(journal: true, health: false))
    let text = prompt(assembly)
    #expect(text.contains(InsightHarness.journalText))
    #expect(text.contains(InsightHarness.reasonNote))
    for secret in ["72.4", "Resting heart rate", "8123"] { #expect(!text.contains(secret)) }
    #expect(replay.includingText == [true])
    #expect(assembly.sensitiveSources == [InsightHarness.journalText, InsightHarness.reasonNote])
    #expect(assembly.resultClass == .general)
  }

  @Test func shouldIncludeHealthAndActivityDataOnlyWithTheHealthConsent() async throws {
    let (assembly, _) = try await assemble(InsightConsentSnapshot(journal: false, health: true))
    let text = prompt(assembly)
    for shown in [#""kg":"72.4""#, "Resting heart rate", #""value":"8123","source":"health""#] { #expect(text.contains(shown)) }
    #expect(!text.contains(InsightHarness.journalText))
    #expect(!text.contains(InsightHarness.reasonNote))
    #expect(assembly.dataClasses.contains(.health))
    #expect(assembly.rowCounts[.health] == 5)
    #expect(assembly.resultClass == .health)
  }

  @Test func shouldDropReplayTextTheSourceSendsWithoutConsent() async throws {
    let (assembly, _) = try await assemble(.none, replay: StubReplay(try InsightHarness.replayState(reasonNote: "a note the replay should not have sent")))
    #expect(!prompt(assembly).contains("a note the replay should not have sent"))
    #expect(assembly.sensitiveSources.isEmpty)
  }

  @Test func shouldKeepAnActivityOnlyContextInTheActivityClass() async throws {
    let harness = try InsightHarness()
    try await harness.stores.activity.write { transaction in
      let id = MetricID<ActivityMetric>(recordUUID: BuiltinMetric.steps.id)
      try MetricRecord(id: id, name: "Steps", valueType: .known(.count), direction: .known(.higher)).create(in: &transaction)
    }
    let assembly = try await InsightAssembler(stores: harness.stores, replay: harness.replay).assemble(
      question: Self.question, consent: InsightConsentSnapshot(journal: false, health: true), today: Self.today)
    #expect(assembly.resultClass == .activity)
  }

  @Test func shouldNarrowTheWindowUntilThePromptFitsTheBudget() async throws {
    let harness = try InsightHarness()
    try await harness.stores.main.write { transaction in
      for day in 0..<400 {
        let date = InsightHarness.day("2026-11-21", plus: -day)
        try MealRecord(id: MemoirStoreFixture.commandID(1000 + day), date: date, name: "Lentil soup", calories: 420, mealType: .known(.cooked), loggedAtMillis: 1)
          .create(in: &transaction)
      }
    }
    let whole = try await InsightAssembler(stores: harness.stores, replay: harness.replay).assemble(question: Self.question, consent: .none, today: Self.today)
    #expect(whole.windowStart == nil)
    #expect(whole.rowCounts[.meals] == 400)
    let budget = prompt(whole).utf16.count / 4
    let narrowed = try await InsightAssembler(stores: harness.stores, replay: harness.replay, budget: budget).assemble(
      question: Self.question, consent: .none, today: Self.today)
    #expect(prompt(narrowed).utf16.count <= budget)
    #expect(narrowed.windowStart == Self.today.adding(days: -90))
    #expect(narrowed.rowCounts[.meals] == 91)
    #expect(prompt(narrowed).contains(#""windowStart":"2026-08-23""#))
    await #expect(throws: InsightError.self) {
      _ = try await InsightAssembler(stores: harness.stores, replay: harness.replay, budget: 500).assemble(question: Self.question, consent: .none, today: Self.today)
    }
  }

  private func assemble(_ consent: InsightConsentSnapshot, modules: Set<MemoirModule>) async throws -> (InsightAssembly, StubReplay) {
    let replay = try StubReplay(InsightHarness.replayState())
    let harness = try InsightHarness(replay: replay)
    try await harness.seed()
    let euro = try MemoirStoreFixture.currency("EUR")
    var settings = AccountSettingsRecord(defaultCurrency: euro, enabledCurrencies: [euro])
    for module in MemoirModule.allCases { settings.setModule(module, enabled: modules.contains(module)) }
    let date = try MemoirStoreFixture.date("2026-11-20")
    let meal = MealRecord(id: MemoirStoreFixture.commandID(900), date: date, name: "Lentil soup", calories: 420, mealType: .known(.cooked), loggedAtMillis: 1)
    try await MoneyReadsFixture.seed(harness.stores.main, [settings, meal])
    let assembler = InsightAssembler(stores: harness.stores, replay: replay)
    return (try await assembler.assemble(question: Self.question, consent: consent, today: Self.today), replay)
  }

  @Test func shouldReadOnlyTheEnabledModulesOnTopOfConsent() async throws {
    let (assembly, replay) = try await assemble(InsightConsentSnapshot(journal: true, health: true), modules: [.money, .journal])
    let text = prompt(assembly)
    #expect(text.contains(InsightHarness.journalText))
    for hidden in [InsightHarness.reasonNote, "Evening run", "Pages read", "72.4", "8123", "Resting heart rate", "early_bird", "Lentil soup", #""hpStart""#, "level_up"] {
      #expect(!text.contains(hidden), "\(hidden) reached the prompt with its module off")
    }
    #expect(text.contains(#""intensityMode":null"#), "the intensity mode is Hero's")
    #expect(replay.includingText == [false], "reason and reflection text rides the quests, which are off")
    #expect(assembly.dataClasses == [.journalReflectionReason])
    #expect(assembly.questIDs.isEmpty && assembly.resultClass == .general)
    #expect(assembly.sensitiveSources == [InsightHarness.journalText])
  }

  @Test func shouldSplitTheJournalClassBetweenJournalEntriesAndQuestText() async throws {
    let (assembly, replay) = try await assemble(InsightConsentSnapshot(journal: true, health: true), modules: [.hero, .quests, .money, .meals, .body])
    let text = prompt(assembly)
    for shown in [
      InsightHarness.reasonNote, "Evening run", "Pages read", #""kg":"72.4""#, "early_bird", "Lentil soup", #""intensityMode":"standard""#, #""type":"quest_complete""#,
      #""type":"meal""#, #""type":"level_up""#,
    ] {
      #expect(text.contains(shown), "\(shown) is missing with its module on")
    }
    #expect(!text.contains(InsightHarness.journalText), "journal entries need the Journal module")
    #expect(!text.contains(#""type":"journal""#), "a journal reward reveals a journal day")
    #expect(replay.includingText == [true])
    #expect(assembly.sensitiveSources == [InsightHarness.reasonNote])
    #expect(assembly.resultClass == .health)
  }

  @Test func shouldKeepHeroProgressWithoutQuestData() async throws {
    let (assembly, _) = try await assemble(.none, modules: [.hero, .money])
    let text = prompt(assembly)
    #expect(text.contains("early_bird"), "titles are Hero's")
    #expect(text.contains(#""type":"level_up""#), "a level is Hero's own")
    for hidden in ["Evening run", #""hpStart""#, #""state":"missed""#, #""type":"quest_complete""#, #""type":"journal""#, #""type":"meal""#] {
      #expect(!text.contains(hidden), "\(hidden) reached the prompt with its module off")
    }
    #expect(assembly.dataClasses == [.heroEvents, .progressionEvents] && assembly.questIDs.isEmpty)
  }

  @Test func shouldWriteInstantsAsTheReferenceDoes() {
    #expect(InsightRows.instant(0) == .string("1970-01-01T00:00:00.000Z"))
    #expect(InsightRows.instant(1_763_600_000_123) == .string("2025-11-20T00:53:20.123Z"))
    #expect(InsightRows.instant(-1) == .string("1969-12-31T23:59:59.999Z"))
  }
}
