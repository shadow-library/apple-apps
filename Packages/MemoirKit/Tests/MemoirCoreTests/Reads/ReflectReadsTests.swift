import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Reflect reads", TestTimeLimit.standard)
struct ReflectReadsTests {
  private static let today = MoneyReadsFixture.date("2026-11-21")
  private static let run = MoneyReadsFixture.id(500)
  private static let stretch = MoneyReadsFixture.id(501)

  /// Two daily quests from Monday 9 November, replayed through the projection up to today: Run completed on the 9th, partial on the 10th, skipped
  /// for being too tired on the 11th; Stretch completed on the 9th; every other closed day a miss.
  private static func lived() async throws -> MemoirStores {
    let horizon = HorizonBox()
    horizon.set(MoneyReadsFixture.stamp(today))
    let reconciler = try MemoirReconciler(appVersion: "1", horizon: horizon.function)
    let stores = try MemoirStores.openInMemory(wallClock: MoneyReadsFixture.wallClock(today), projection: reconciler)
    let start = MoneyReadsFixture.date("2026-11-09")
    let created = MoneyReadsFixture.date("2026-11-08")
    try await MoneyReadsFixture.seed(stores.main, [QuestRecord(id: run, name: "Run"), QuestRecord(id: stretch, name: "Stretch")])
    let commands: [MemoirCommand] = [
      try MoneyReadsFixture.command(1, .questCreate(QuestCreation(questId: run, schedule: try ProjectionSupport.routine(starting: start))), on: created),
      try MoneyReadsFixture.command(2, .questCreate(QuestCreation(questId: stretch, schedule: try ProjectionSupport.routine(starting: start))), on: created, hour: 13),
      try MoneyReadsFixture.command(3, .questComplete(Occurrence(quest: run, date: start)), on: start),
      try MoneyReadsFixture.command(4, .questComplete(Occurrence(quest: stretch, date: start)), on: start, hour: 13),
      try MoneyReadsFixture.command(5, .questPartial(Occurrence(quest: run, date: MoneyReadsFixture.date("2026-11-10"))), on: MoneyReadsFixture.date("2026-11-10")),
      try MoneyReadsFixture.command(
        6, .questSkip(QuestBreak(occurrence: Occurrence(quest: run, date: MoneyReadsFixture.date("2026-11-11")), reasonTag: .tooTired)),
        on: MoneyReadsFixture.date("2026-11-11")),
    ]
    for command in commands { try await ProjectionSupport.append([command], to: stores.main) }
    return stores
  }

  @Test func shouldCountAPartialAsHalfAndLeaveMovedOccurrencesOut() {
    func row(_ state: QuestLogState, _ day: Int) -> QuestLogRow {
      QuestLogRow(
        occurrence: Occurrence(quest: Self.run, date: MoneyReadsFixture.date("2026-11-\(String(format: "%02d", day))")),
        entry: QuestLogEntry(
          id: MoneyReadsFixture.id(day), state: state, xpAwarded: 0, coinsAwarded: 0, statAffinity: .body, strictness: .routine, intensityModeAtLog: .standard,
          crownSliceWeight: .zero, rulesetVersion: 1, reasonTag: nil, reasonNote: nil, reflection: nil, rescheduledToMinute: nil, postponedToDate: nil,
          performedAtMillis: nil, createdAtMillis: 0))
    }
    let adherence = Adherence([row(.completed, 1), row(.partial, 2), row(.late, 3), row(.recovery, 4), row(.skipped, 5), row(.missed, 6), row(.postponed, 7), row(.rescheduled, 8)])
    #expect(adherence.occurrences == 6, "postponed and rescheduled resolve where they moved to")
    #expect(adherence.held == Halves(7))
    #expect(adherence.ratio == Fraction(numerator: 7, denominator: 12))
    #expect(adherence.percent == 58)
    #expect(Adherence.empty.ratio == nil)
  }

  @Test func shouldReadInsightStatisticsFromTheProjection() async throws {
    let stores = try await Self.lived()
    let insights = try await ReflectReads.insights(in: stores, period: .thirtyDays, bodyClasses: [], today: Self.today)
    #expect(insights.window == DateSpan(start: MoneyReadsFixture.date("2026-10-23"), end: Self.today))
    #expect(insights.kept.occurrences == 24, "12 closed days of two quests; today is still open")
    #expect(insights.kept.heldHalves == 5)
    #expect(insights.kept.percent == 10)
    #expect(insights.previousKept?.ratio == nil)
    #expect(insights.xpDelta == nil, "nothing earned the 30 days before")
    #expect(insights.byQuest.map(\.name) == ["Run", "Stretch"])
    #expect(insights.byQuest.map(\.adherence.percent) == [13, 8])
    #expect(insights.byWeekday.map(\.weekday) == LocalDate.Weekday.allCases)
    #expect(insights.byWeekday.map(\.adherence.percent) == [50, 13, 0, 0, 0, 0, 0])
    #expect(insights.weakestWeekday == .wednesday)
    #expect(insights.reasons == [ReasonCount(reason: .tooTired, count: 1)])
    #expect(insights.xpByMonth.map(\.month) == [10, 11])
    #expect(insights.xpByMonth.first?.xp == 0)
    let logged = try await stores.main.read { transaction in try ReadSources.allQuestLogs(in: transaction) }
    #expect(insights.xp == logged.map(\.entry.xpAwarded).reduce(0, +))
    #expect(insights.xp > 0)
    #expect(insights.spent == nil, "no settings, no home currency")
    #expect(insights.bodyClasses.isEmpty && insights.body.isEmpty)
    let year = try await ReflectReads.insights(in: stores, period: .year, bodyClasses: [], today: Self.today)
    #expect(year.previousWindow == nil && year.previousXP == nil)
    #expect(year.xpByMonth.count == 13)
  }

  @Test func shouldReadBodyTrendsOnlyFromTheClassesAskedFor() async throws {
    let stores = try await Self.lived()
    try await MoneyReadsFixture.seed(
      stores.restricted,
      [("2026-11-01", "74"), ("2026-11-20", "72.5")].map { WeightRecord(date: MoneyReadsFixture.date($0.0), kilograms: MoneyReadsFixture.decimal($0.1), loggedAtMillis: 1) })
    try await MoneyReadsFixture.write(stores.activity) { transaction in
      let steps = MetricID<ActivityMetric>(recordUUID: BuiltinMetric.steps.id)
      for (day, value) in [("2026-11-18", "4000"), ("2026-11-19", "6001")] {
        _ = try MetricDays.setImported(MoneyReadsFixture.decimal(value), for: steps, on: MoneyReadsFixture.date(day), in: &transaction)
      }
    }
    let activityOnly = try await ReflectReads.insights(in: stores, period: .thirtyDays, bodyClasses: [.activity], today: Self.today)
    #expect(activityOnly.bodyClasses == [.activity])
    #expect(activityOnly.body.map(\.syncClass) == [.activity])
    #expect(activityOnly.body.first?.mean == Fraction(numerator: 10_001, denominator: 2))
    let both = try await ReflectReads.insights(in: stores, period: .thirtyDays, bodyClasses: [.activity, .health], today: Self.today)
    #expect(both.body.first?.subject == .weight)
    #expect(both.body.first?.change == MoneyReadsFixture.decimal("-1.5"))
  }

  @Test func shouldStreamFilterSearchAndPageTheHistory() async throws {
    let stores = try await Self.lived()
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(), MoneyReadsFixture.expense(1, 990, "EUR", on: "2026-11-20", merchant: "Run shop")])
    let first = try await ReflectReads.history(in: stores, matching: try .page(1), bodyClasses: [], today: Self.today)
    #expect(first.classes == [.general])
    #expect(first.records.items.count == HistoryQuery.pageSize)
    #expect(first.records.items.first?.date == MoneyReadsFixture.date("2026-11-21"), "the newest day first")
    #expect(first.records.items.contains { $0.kind == .expense } && first.records.items.contains { $0.kind == .hero })
    let dates = first.records.items.map(\.date)
    #expect(dates == dates.sorted(by: >))
    let quests = try await ReflectReads.history(in: stores, matching: HistoryQuery(kinds: [.quest], page: .all), bodyClasses: [], today: Self.today)
    #expect(quests.records.total == 24)
    #expect(quests.totals.outcomes == 24 && quests.totals.kept == 3)
    let searched = try await ReflectReads.history(in: stores, matching: HistoryQuery(search: " RUN ", page: .all), bodyClasses: [], today: Self.today)
    #expect(searched.records.total == 13, "Run's twelve logs and the expense at the Run shop")
    #expect(searched.totals.expenses == 1 && searched.totals.spent?.totalMinor == 990)
    let last = try await ReflectReads.history(in: stores, matching: try .page(2), bodyClasses: [], today: Self.today)
    #expect(last.records.offset == 20)
    #expect(last.totalRecords == first.totalRecords)
  }

  @Test func shouldReadTheWeeklyReviewOfLastWeek() async throws {
    let stores = try await Self.lived()
    let review = try await ReflectReads.review(in: stores, bodyClasses: [], today: Self.today)
    #expect(review.week == DateSpan(start: MoneyReadsFixture.date("2026-11-09"), end: MoneyReadsFixture.date("2026-11-15")))
    #expect(review.isoWeek == IsoWeek(year: 2026, week: 46))
    #expect(review.kept.occurrences == 14)
    #expect(review.kept.held == 3, "the review counts a partial as kept, as the web's does")
    #expect(review.kept.partials == 1 && review.kept.missesWithReason == 1)
    #expect(review.kept.percent == 21)
    #expect(review.kept.quests.map(\.name) == ["Run", "Stretch"])
    #expect(review.kept.quests.first?.days == [.kept, .partial, .missed, .missed, .missed, .missed, .missed])
    #expect(review.kept.topReason == ReasonCount(reason: .tooTired, count: 1))
    #expect(review.money == nil)
    #expect(review.body.thin.isEmpty && review.body.classes.isEmpty)
    #expect(review.answers == .none)
    #expect(ReviewStep.allCases.count == 5)
    #expect(WeeklyReview.isoWeek(of: MoneyReadsFixture.date("2027-01-01")) == IsoWeek(year: 2026, week: 53))
  }

  private static func reviewTablesExist(_ stores: MemoirStores) async throws -> Bool {
    try await stores.main.read { transaction in
      try transaction.database.tableExists(WeeklyReviewAnswers.answerTable) || transaction.database.tableExists(WeeklyReviewAnswers.completionTable)
    }
  }

  @Test func shouldKeepReviewAnswersLocalCreatedOnFirstWriteAndClearedWithTheirWeek() async throws {
    let stores = try MemoirStores.openInMemory()
    let week = MoneyReadsFixture.date("2026-11-09")
    let nextWeek = MoneyReadsFixture.date("2026-11-16")
    #expect(try await stores.main.read { try WeeklyReviewAnswers.answers(week: week, in: $0) } == .none, "read before any write, without the tables")
    #expect(try await !Self.reviewTablesExist(stores))
    try await WeeklyReviewAnswers.save("Slept earlier", for: .better, week: week, in: stores)
    try await WeeklyReviewAnswers.save("Less", for: .carry, week: week, in: stores)
    try await WeeklyReviewAnswers.save("", for: .carry, week: week, in: stores)
    try await WeeklyReviewAnswers.complete(week: week, atMillis: 5, in: stores)
    try await WeeklyReviewAnswers.complete(week: week, atMillis: 9, in: stores)
    #expect(try await Self.reviewTablesExist(stores))
    let answers = try await stores.main.read { try WeeklyReviewAnswers.answers(week: week, in: $0) }
    #expect(answers == ReviewAnswers(answers: [.better: "Slept earlier"], completedAtMillis: 5))
    #expect(try await stores.main.pendingChanges(limit: 100).isEmpty, "answers never sync")

    try await WeeklyReviewAnswers.save("Plan Sundays", for: .change, week: nextWeek, in: stores)
    #expect(try await stores.main.read { try WeeklyReviewAnswers.answers(week: week, in: $0) } == .none, "a new week's review clears the last one's")
    #expect(try await stores.main.read { try WeeklyReviewAnswers.answers(week: nextWeek, in: $0) }.answers == [.change: "Plan Sundays"])

    try await stores.main.write { transaction in try WeeklyReviewAnswers.clear(in: transaction.database) }
    #expect(try await !Self.reviewTablesExist(stores))
  }

  @Test func shouldReEmitTheReviewWhenAnAnswerIsSaved() async throws {
    let stores = try await Self.lived()
    var iterator = ReflectReads.observeReview(in: stores, bodyClasses: [.health], today: Self.today).makeAsyncIterator()
    let first = try #require(try await iterator.next())
    #expect(first.answers == .none)
    #expect(first.body.classes == [.health])
    try await WeeklyReviewAnswers.save("Ran twice", for: .better, week: first.week.start, in: stores)
    let second = try #require(try await iterator.next())
    #expect(second.answers.answers == [.better: "Ran twice"])
    try await MoneyReadsFixture.seed(
      stores.restricted,
      [("2026-11-10", "70.4"), ("2026-11-12", "70")].map { WeightRecord(date: MoneyReadsFixture.date($0.0), kilograms: MoneyReadsFixture.decimal($0.1), loggedAtMillis: 1) })
    let third = try #require(try await iterator.next())
    #expect(third.body.series.map(\.subject) == [.weight], "the restricted store's change re-read the body step")
    #expect(third.body.series.first?.change == MoneyReadsFixture.decimal("-0.4"))
    #expect(!third.body.thin.contains(.weight))
  }
}
