import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Log reads", TestTimeLimit.standard)
struct LogReadsTests {
  private static let today = MoneyReadsFixture.date("2026-11-21")
  private static let quest = MoneyReadsFixture.id(900)

  /// `journalWordCount` and `journalExcerpt` (`lib/data/quick-logs.rules.ts:115-134`).
  @Test func shouldCountJournalWordsAndCutExcerptsAsTheWeb() {
    #expect(JournalText.wordCount("**Bold** move _today_\n- item one\n> a quote\n## Heading here") == 9)
    #expect(JournalText.wordCount("   \n ") == 0)
    #expect(JournalText.wordCount("snake_case_word stays one") == 3, "an underscore pair inside a word reads as italic, as the web's pattern does")
    #expect(JournalText.excerpt("> Short and **plain**") == "Short and plain")
    #expect(JournalText.excerpt("a > b - c\n  # d") == "a > b - c d", "marks count only at a line's start, after up to three spaces")
    let long = String(repeating: "word ", count: 40)
    let excerpt = JournalText.excerpt(long)
    #expect(excerpt.hasSuffix("word\u{2026}"))
    #expect(excerpt.utf16.count == 160)
    #expect(JournalText.excerpt(String(repeating: "é", count: 200), maxLength: 140).utf16.count == 141)
  }

  @Test func shouldReadTheJournalWithStreakTrendAndOnThisDay() async throws {
    let stores = try MemoirStores.openInMemory()
    let entries = [("2026-11-21", "Today was **good**", 4), ("2026-11-20", "One two three", 3), ("2026-11-18", "Gap", nil), ("2025-11-21", "Last year, same day", 2)]
    try await MoneyReadsFixture.seed(
      stores.main,
      entries.enumerated().map { index, entry in
        JournalEntryRecord(
          id: MoneyReadsFixture.id(index + 1), date: MoneyReadsFixture.date(entry.0), text: entry.1, mood: entry.2,
          loggedAtMillis: MoneyReadsFixture.millis(MoneyReadsFixture.date(entry.0)))
      })
    let journal = try await LogReads.journal(in: stores, today: Self.today)
    #expect(journal.today?.wordCount == 3)
    #expect(journal.entries.map(\.entry.date.isoString) == ["2026-11-21", "2026-11-20", "2026-11-18", "2025-11-21"])
    #expect(journal.writingStreakDays == 2)
    #expect(journal.words.count == 28)
    #expect(journal.words.suffix(4).map(\.value) == [1, nil, 3, 3])
    #expect(journal.moods.last?.value == 4)
    #expect(journal.onThisDay == OnThisDay(year: 2025, entry: MoneyReadsFixture.id(4), excerpt: "Last year, same day"))
  }

  /// `meals` (`lib/sync/synced-quick-log-provider.ts:223-253`): blank days are not zero, and presets by use.
  @Test func shouldReadMealsWithAFourteenDayAverageOverLoggedDaysOnly() async throws {
    let stores = try MemoirStores.openInMemory()
    let soup = MealPresetRecord(id: MoneyReadsFixture.id(20), name: "Soup", calories: 300, mealType: .known(.cooked))
    let bowl = MealPresetRecord(id: MoneyReadsFixture.id(21), name: "Bowl", calories: 500, mealType: .known(.cooked))
    func meal(_ number: Int, _ date: String, _ calories: Int, preset: UUID? = nil, hour: Int = 12) -> MealRecord {
      MealRecord(
        id: MoneyReadsFixture.id(number), date: MoneyReadsFixture.date(date), name: "Meal \(number)", calories: calories, mealType: .known(.cooked), preset: preset,
        loggedAtMillis: MoneyReadsFixture.millis(MoneyReadsFixture.date(date), hour: hour))
    }
    try await MoneyReadsFixture.seed(
      stores.main,
      [soup, bowl, meal(1, "2026-11-21", 500, hour: 13), meal(2, "2026-11-21", 301, preset: soup.id, hour: 8), meal(3, "2026-11-20", 0), meal(4, "2026-11-01", 900)])
    let meals = try await LogReads.meals(in: stores, on: Self.today, today: Self.today)
    #expect(meals.meals.map(\.id) == [MoneyReadsFixture.id(2), MoneyReadsFixture.id(1)])
    #expect(meals.totalCalories == 801)
    #expect(meals.calories.count == 14)
    #expect(meals.calories.suffix(3).map(\.value) == [nil, 0, 801])
    #expect(meals.averageCalories == 401, "801 and 0 over two logged days, 400.5 halves up")
    #expect(meals.presets.map(\.preset.name) == ["Soup", "Bowl"])
    #expect(meals.presets.map(\.usageCount) == [1, 0])
  }

  @Test func shouldReadWeightFromTheRestrictedStoreOnly() async throws {
    let stores = try MemoirStores.openInMemory()
    let empty = try await LogReads.weight(in: stores, today: Self.today)
    #expect(empty.entries.isEmpty && empty.sevenDayAverage == nil && empty.ninetyDayChange == nil, "an empty restricted store reads as empty, not an error")
    #expect(WeightOverview.heldClass == .health)
    let weights = [("2026-11-21", "72.4"), ("2026-11-18", "72.9"), ("2026-11-10", "73.5"), ("2026-09-01", "75"), ("2026-08-01", "80")].map {
      WeightRecord(date: MoneyReadsFixture.date($0.0), kilograms: MoneyReadsFixture.decimal($0.1), loggedAtMillis: 1)
    }
    try await MoneyReadsFixture.seed(stores.restricted, weights)
    let weight = try await LogReads.weight(in: stores, today: Self.today)
    #expect(weight.today?.kilograms == MoneyReadsFixture.decimal("72.4"))
    #expect(weight.entries.count == 5)
    #expect(weight.trend.map(\.date.isoString) == ["2026-09-01", "2026-11-10", "2026-11-18", "2026-11-21"], "the last 90 days, oldest first")
    #expect(weight.sevenDayAverage == Fraction(numerator: 1453, denominator: 20), "72.4 and 72.9, exactly 72.65")
    #expect(weight.sevenDayAverage?.rounded(toPlaces: 1) == MoneyReadsFixture.decimal("72.7"))
    #expect(weight.ninetyDayChange == MoneyReadsFixture.decimal("-2.6"))
    #expect(weight.ninetyDayStart == MoneyReadsFixture.decimal("75"))
    #expect(weight.lightest == MoneyReadsFixture.decimal("72.4") && weight.heaviest == MoneyReadsFixture.decimal("75"))
    #expect(try await stores.main.pendingChanges(limit: 100).isEmpty)
  }

  @Test func shouldConvertKilogramsAndPoundsExactlyAndRoundHalfUp() {
    #expect(WeightConversion.convert(MoneyReadsFixture.decimal("72.4"), from: .kilograms, to: .pounds) == MoneyReadsFixture.decimal("159.6"))
    #expect(WeightConversion.convert(MoneyReadsFixture.decimal("100"), from: .pounds, to: .kilograms, places: 3) == MoneyReadsFixture.decimal("45.359"))
    #expect(
      WeightConversion.convert(MoneyReadsFixture.decimal("1"), from: .pounds, to: .kilograms, places: 8) == MoneyReadsFixture.decimal("0.45359237"), "the definition, exactly")
    #expect(WeightConversion.convert(MoneyReadsFixture.decimal("0.45359237"), from: .kilograms, to: .pounds, places: 18) == MoneyReadsFixture.decimal("1"))
    #expect(WeightConversion.convert(MoneyReadsFixture.decimal("1.25"), from: .kilograms, to: .kilograms) == MoneyReadsFixture.decimal("1.3"), "a half rounds up")
    #expect(WeightConversion.convert(MoneyReadsFixture.decimal("-1.25"), from: .kilograms, to: .kilograms) == MoneyReadsFixture.decimal("-1.2"), "toward positive infinity")
    #expect(WeightOverview.isAccepted(MoneyReadsFixture.decimal("30")) && WeightOverview.isAccepted(MoneyReadsFixture.decimal("250")))
    #expect(!WeightOverview.isAccepted(MoneyReadsFixture.decimal("29.9")) && !WeightOverview.isAccepted(MoneyReadsFixture.decimal("250.01")))
  }

  /// Synced values may hold 30 significant digits or 18 places; arithmetic past `Int128` or `Int` leaves a value out instead of trapping or clamping.
  @Test func shouldLeaveOutValuesWhoseArithmeticWouldOverflow() async throws {
    let huge = MoneyReadsFixture.decimal("123456789012345678901234567890")
    let tiny = MoneyReadsFixture.decimal("0.000000000000000001")
    #expect(ExactDecimal(huge) != nil && ExactDecimal(tiny) != nil)
    #expect(ExactDecimal(MoneyReadsFixture.decimal("1234567890123456789012345678901")) == nil, "31 digits are not read")
    #expect(ExactDecimal(MoneyReadsFixture.decimal("0.0000000000000000001")) == nil, "19 places are not read")
    #expect(DecimalText.mean([huge, tiny]) == nil, "the sum at 18 places leaves Int128")
    #expect(DecimalText.mean([huge]) == nil, "the mean's terms leave Int")
    #expect(DecimalText.mean([tiny, tiny]) == Fraction(numerator: 1, denominator: 1_000_000_000_000_000_000))
    #expect(huge.minus(tiny) == nil)
    #expect(tiny.minus(tiny) == MoneyReadsFixture.decimal("0"))
    #expect(ExactDecimal(tiny)! < ExactDecimal(huge)!)
    #expect(ExactDecimal(MoneyReadsFixture.decimal("-123456789012345678901234567890"))! < ExactDecimal(MoneyReadsFixture.decimal("-0.000000000000000001"))!)
    #expect(ExactDecimal(MoneyReadsFixture.decimal("1.5")) == ExactDecimal(MoneyReadsFixture.decimal("1.5")))
    #expect(WeightConversion.convert(huge, from: .kilograms, to: .pounds) == MoneyReadsFixture.decimal("272175629877428667729209307224.5"), "30 digits still convert exactly")
    #expect(WeightConversion.convert(huge, from: .kilograms, to: .pounds, places: 18) == nil, "but not to 18 places")
    #expect(WeightConversion.convert(huge, from: .pounds, to: .kilograms, places: 18) == nil)
    #expect(WeightConversion.convert(tiny, from: .kilograms, to: .pounds, places: 18) == MoneyReadsFixture.decimal("0.000000000000000002"))
    #expect(!WeightOverview.isAccepted(huge) && !WeightOverview.isAccepted(tiny))
    #expect(SpendDelta.fraction(current: .min, previous: .max) == nil, "a change outside Int is no delta, not a clamped one")

    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(
      stores.restricted,
      [WeightRecord(date: Self.today, kilograms: huge, loggedAtMillis: 1), WeightRecord(date: MoneyReadsFixture.date("2026-11-20"), kilograms: tiny, loggedAtMillis: 1)])
    let weight = try await LogReads.weight(in: stores, today: Self.today)
    #expect(weight.entries.count == 2)
    #expect(weight.sevenDayAverage == nil && weight.ninetyDayChange == nil)
  }

  /// `SIDE_QUEST_DAILY_REWARD_LIMIT` and `nextSideQuestReward` (`quick-logs.rules.ts:102,192-197`), as replay's `logSideQuest` grants them.
  @Test func shouldCapSideQuestRewardsAtThreeADay() async throws {
    let stores = try MemoirStores.openInMemory()
    let dates = ["2026-11-21", "2026-11-21", "2026-11-21", "2026-11-21", "2026-11-20"]
    try await MoneyReadsFixture.write(stores.main) { transaction in
      for (index, date) in dates.enumerated() {
        let id = MoneyReadsFixture.id(30 + index)
        let command = try MoneyReadsFixture.command(30 + index, .sideQuestLog(SideQuestEntry(id: id, date: MoneyReadsFixture.date(date))), on: Self.today, hour: 8 + index)
        try command.append(in: &transaction)
        try SideQuestRecord(id: id, date: MoneyReadsFixture.date(date), name: "Walk \(index)", loggedAtMillis: command.instantMillis).create(in: &transaction)
      }
    }
    let sideQuests = try await LogReads.sideQuests(in: stores, today: Self.today)
    #expect(sideQuests.items.map(\.rewarded) == [false, false, true, true, true], "newest first: the backdated one and the fourth carry no reward")
    #expect(sideQuests.rewardedToday == 3)
    #expect(sideQuests.rewardLimit == 3)
    #expect(sideQuests.isRewardCapReached && sideQuests.remainingRewardsToday == 0)
    #expect(sideQuests.xpThisMonth == 24)
    #expect(sideQuests.loggedThisMonth == 5)
  }

  /// `deriveCapAdvisory` (`lib/data/entry-caps.ts:16-33`).
  @Test func shouldAdviseAtEightyPercentAndAtTheLimitWithoutBlocking() async throws {
    #expect(EntryCapAdvisory(module: .meals, used: 79).level == .clear)
    #expect(EntryCapAdvisory(module: .meals, used: 80).level == .approaching)
    #expect(EntryCapAdvisory(module: .meals, used: 99).level == .approaching)
    #expect(EntryCapAdvisory(module: .meals, used: 100).level == .reached)
    #expect(EntryCapAdvisory(module: .meals, used: 140).level == .reached)
    #expect(EntryCapAdvisory(module: .meals, used: 4, limit: 5).level == .approaching)
    #expect(EntryCapAdvisory(module: .meals, used: 3, limit: 0).level == .clear)
    #expect(EntryCapAdvisory(module: .meals, used: 3, limit: 4).ratio == Fraction(numerator: 3, denominator: 4))

    let stores = try MemoirStores.openInMemory()
    try await MoneyReadsFixture.seed(stores.main, (0..<80).map { MoneyReadsFixture.expense($0, 100, "EUR", on: "2026-11-\(String(format: "%02d", 1 + $0 % 21))") })
    try await MoneyReadsFixture.seed(stores.restricted, [WeightRecord(date: Self.today, kilograms: MoneyReadsFixture.decimal("70"), loggedAtMillis: 1)])
    let general = try await LogReads.entryCaps(in: stores, today: Self.today, includeHealth: false)
    #expect(general.classes == [.general])
    #expect(general.advisory(.expenses)?.level == .approaching)
    #expect(general.advisory(.weight) == nil, "weights are counted only when health data is asked for")
    let withHealth = try await LogReads.entryCaps(in: stores, today: Self.today, includeHealth: true)
    #expect(withHealth.classes == [.general, .health])
    #expect(withHealth.advisory(.weight)?.used == 1)
  }

  private static func thresholds(_ stores: MemoirStores) async throws {
    try await MoneyReadsFixture.seed(stores.main, [QuestRecord(id: quest, name: "Move 8,000 steps")])
    let steps = MetricID<ActivityMetric>(recordUUID: BuiltinMetric.steps.id)
    try await MoneyReadsFixture.write(stores.activity) { transaction in
      try QuestThresholdRecord(quest: quest, metric: steps, value: MoneyReadsFixture.decimal("8000"), comparison: .known(.atLeast)).create(in: &transaction)
      try MetricDays.enter(MetricEntry(value: MoneyReadsFixture.decimal("9000")), for: steps, on: Self.today, in: &transaction)
      _ = try MetricDays.setImported(MoneyReadsFixture.decimal("4000"), for: steps, on: MoneyReadsFixture.date("2026-11-20"), in: &transaction)
      _ = try MetricDays.setImported(MoneyReadsFixture.decimal("8500"), for: steps, on: MoneyReadsFixture.date("2026-11-19"), in: &transaction)
    }
  }

  @Test func shouldReadMetricsFromTheirClassStoresWithThresholdOffers() async throws {
    let stores = try MemoirStores.openInMemory()
    try await Self.thresholds(stores)
    let metrics = try await LogReads.metrics(in: stores, classes: [.activity], activeQuests: [Self.quest], today: Self.today)
    #expect(metrics.classes == [.activity])
    #expect(metrics.series.map(\.metric.builtin) == [.steps, .workoutMinutes])
    let steps = try #require(metrics.series.first)
    #expect(steps.today == MetricDayReading(date: Self.today, value: MoneyReadsFixture.decimal("9000"), source: .entry(.known(.manual))))
    #expect(steps.days.suffix(3).map(\.value?.value) == ["8500", "4000", "9000"].map { Optional(MoneyReadsFixture.decimal($0)) })
    #expect(steps.days.suffix(3).map(\.value?.source) == [.imported, .imported, .entry(.known(.manual))])
    #expect(metrics.offers.map(\.date) == [MoneyReadsFixture.date("2026-11-19"), Self.today], "crossed days offer the quest; the 4,000 day does not")
    #expect(metrics.offers.first?.questName == "Move 8,000 steps")
    let inactive = try await LogReads.metrics(in: stores, classes: [.activity], activeQuests: [], today: Self.today)
    #expect(inactive.offers.isEmpty)
  }

  @Test func shouldReadAnEmptyRestrictedStoreAsEmptyNotAnError() async throws {
    let stores = try MemoirStores.openInMemory()
    let metrics = try await LogReads.metrics(in: stores, classes: [.health], activeQuests: [], today: Self.today)
    #expect(metrics.classes == [.health])
    #expect(metrics.series.allSatisfy { $0.days.allSatisfy { $0.value == nil } && $0.metric.reference.metricClass == .health })
    #expect(metrics.offers.isEmpty)
    let none = try await LogReads.metrics(in: stores, classes: [], activeQuests: [], today: Self.today)
    #expect(none.series.isEmpty && none.classes.isEmpty)
  }

  @Test func shouldKeepEveryHealthAndActivityValueOutOfTheMainStore() async throws {
    let stores = try MemoirStores.openInMemory()
    try await Self.thresholds(stores)
    try await MoneyReadsFixture.seed(stores.restricted, [WeightRecord(date: Self.today, kilograms: MoneyReadsFixture.decimal("71.35"), loggedAtMillis: 1)])
    try await MoneyReadsFixture.write(stores.activity) { transaction in
      let workout = MetricID<ActivityMetric>(recordUUID: BuiltinMetric.workoutMinutes.id)
      try MetricDays.enter(MetricEntry(value: MoneyReadsFixture.decimal("4321.75")), for: workout, on: Self.today, in: &transaction)
    }
    _ = try await LogReads.metrics(in: stores, classes: [.general, .activity, .health], activeQuests: [Self.quest], today: Self.today)
    _ = try await LogReads.weight(in: stores, today: Self.today)
    _ = try await LogReads.entryCaps(in: stores, today: Self.today, includeHealth: true)
    _ = try await ReflectReads.history(in: stores, matching: try .page(1), bodyClasses: [.activity, .health], today: Self.today)
    _ = try await ReflectReads.review(in: stores, bodyClasses: [.activity, .health], today: Self.today)
    try await WeeklyReviewAnswers.save("Walked more", for: .better, week: MoneyReadsFixture.date("2026-11-09"), in: stores)
    let leaked = try await stores.main.read { transaction in
      let restrictedKinds = MemoirStoreKind.restricted.kinds.map(\.rawValue) + MemoirStoreKind.activity.kinds.map(\.rawValue)
      let database = transaction.database
      var count = 0
      for table in try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") {
        let columns = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))").map { $0["name"] as String }
        for column in columns {
          let sql = "SELECT COUNT(*) FROM \(table) WHERE CAST(\(column) AS TEXT) LIKE '%71.35%' OR CAST(\(column) AS TEXT) LIKE '%4321.75%'"
          count += try Int.fetchOne(database, sql: sql) ?? 0
          if column == "kind" {
            count += try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table) WHERE kind IN (\(restrictedKinds.map { "'\($0)'" }.joined(separator: ",")))") ?? 0
          }
        }
      }
      return count
    }
    #expect(leaked == 0, "no health or activity value or kind lands in any main-store table")
  }

  @Test func shouldReEmitAMultiStoreModelWhenTheRestrictedStoreChanges() async throws {
    let stores = try MemoirStores.openInMemory()
    var iterator = LogReads.observeEntryCaps(in: stores, today: Self.today, includeHealth: true).makeAsyncIterator()
    #expect(try await iterator.next()?.advisory(.weight)?.used == 0)
    try await MoneyReadsFixture.seed(stores.restricted, [WeightRecord(date: Self.today, kilograms: MoneyReadsFixture.decimal("70"), loggedAtMillis: 1)])
    #expect(try await iterator.next()?.advisory(.weight)?.used == 1)
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.expense(1, 100, "EUR", on: "2026-11-21")])
    #expect(try await iterator.next()?.advisory(.expenses)?.used == 1)
  }
}
