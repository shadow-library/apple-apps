import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget close reads", TestTimeLimit.quick)
struct BudgetCloseReadsTests {
  private typealias F = BudgetStandingsFixture

  private static let october = MoneyReadsFixture.date("2026-10-01")
  private static let wholeOctober = days("2026-10", 31)
  /// Home from July, spending 50 000, 60 000 and 70 000 in July, August and September: October's typical month is 60 000.
  private static let history = [
    F.expense(101, 50_000, on: "2026-07-10"), F.expense(102, 60_000, on: "2026-08-10"), F.expense(103, 70_000, on: "2026-09-10"),
  ]

  /// One expense in October, so Home's October has spending to judge.
  private static let spending = history + [F.expense(100, 1_000, on: "2026-10-03")]

  private static func days(_ month: String, _ count: Int) -> [String] {
    (1...count).map { String(format: "\(month)-%02d", $0) }
  }

  private static func settings(scoredFrom: String? = "2026-10-01") -> AccountSettingsRecord {
    var settings = MoneyReadsFixture.settings()
    settings.moneyScoredFrom = scoredFrom.map(MoneyReadsFixture.date)
    return settings
  }

  private static func millis(_ date: String, hour: Int = 0) -> Int64 {
    MoneyReadsFixture.millis(MoneyReadsFixture.date(date), hour: hour)
  }

  private static func book(
    budgets: [BudgetRecord] = [F.home(createdOn: "2026-07-01")], removed: [BudgetRecord] = [], expenses: [ExpenseRecord] = spending, rates: [FxRateRecord] = [],
    covered: [String] = wholeOctober, closes: [MoneyCloseKey: Int64] = [:], deposits: [MoneyCloseKey: SavingsDeposit] = [:], zone: AccountZone = .unset,
    scoredFrom: String? = "2026-10-01"
  ) -> BudgetBook {
    F.book(
      budgets: budgets, removed: removed, expenses: expenses, rates: rates, covered: covered, closes: closes, deposits: deposits, zone: zone,
      settings: settings(scoredFrom: scoredFrom))
  }

  private static func closable(_ book: BudgetBook, today: LocalDate = F.today, now: Int64 = millis("2026-11-21", hour: 12)) -> [ClosablePeriod] {
    BudgetCloseReads.closable(book, today: today, nowMillis: now)
  }

  private static func october(_ book: BudgetBook, budget: UUID = HomeBudget.id, now: Int64 = millis("2026-11-21", hour: 12)) -> ClosablePeriod? {
    closable(book, now: now).first { $0.key == MoneyCloseKey(budget: budget, periodStart: october) }
  }

  @Test func shouldOpenAPeriodAtTheSameMomentItsHistoryStopsCountingNewExpensesInTheAccountsZone() throws {
    let berlin = AccountZone(inForce: "Europe/Berlin", openDay: F.today, lastRecordedOffsetMinutes: 60, staged: nil)
    let earliest = Self.millis("2026-11-03", hour: 23)
    let book = Self.book(
      expenses: Self.history + [
        F.expense(1, 1_000, on: "2026-10-31", loggedOn: "2026-11-03", hour: 22), F.expense(2, 4_000, on: "2026-10-31", loggedOn: "2026-11-03", hour: 23),
      ], zone: berlin)
    let home = try #require(book.liveBudgets(today: F.today).first)
    let period = try #require(home.period(containing: Self.october))

    #expect(book.earliestCloseMillis(of: period) == earliest, "midnight in Berlin after the three grace days, an hour before UTC's")
    #expect(book.cutoffMillis(of: HomeBudget.id, period: period) == earliest, "one moment for both")
    #expect(Self.october(book, now: earliest - 1) == nil)
    let closable = try #require(Self.october(book, now: earliest))
    #expect(closable.spentMinor == 1_000, "logged an hour before the moment counts; at it, not")
    #expect(closable.judgedAtMillis == earliest && closable.closedOn == F.today)
  }

  @Test func shouldHoldAPeriodWhileAnExpenseWaitsForARateThenCloseWithoutIt() throws {
    let book = Self.book(expenses: Self.history + [F.expense(1, 20_000, on: "2026-10-05"), F.expense(2, 3_000, F.usd, on: "2026-10-06")])
    let earliest = Self.millis("2026-11-04")
    let held = Self.millis("2026-11-11")
    #expect(Self.october(book, now: earliest) == nil)
    #expect(Self.october(book, now: held - 1) == nil)
    let closable = try #require(Self.october(book, now: held), "seven days after the earliest moment")
    #expect(closable.spentMinor == 20_000)
    #expect(closable.excluded.awaitingRate == 1 && closable.excluded.currencies == [F.usd])

    let rated = Self.book(
      expenses: Self.history + [F.expense(1, 20_000, on: "2026-10-05"), F.expense(2, 3_000, F.usd, on: "2026-10-06")],
      rates: [MoneyReadsFixture.rate("USD", "EUR", on: "2026-10-06", "0.5")])
    #expect(Self.october(rated, now: earliest)?.spentMinor == 21_500, "the rate arrived: no hold")
  }

  @Test func shouldNeverHoldAPeriodForAnExpenseThatCannotConvert() throws {
    let book = Self.book(expenses: Self.history + [F.expense(1, 20_000, on: "2026-10-05"), F.expense(2, 3_000, MoneyReadsFixture.currency("ZZZ"), on: "2026-10-06")])
    let closable = try #require(Self.october(book, now: Self.millis("2026-11-04")))
    #expect(closable.spentMinor == 20_000 && closable.excluded.unconvertible == 1 && closable.excluded.awaitingRate == 0)
  }

  @Test func shouldCloseNothingBeforeMoneyIsScored() {
    #expect(Self.closable(Self.book(expenses: Self.history, scoredFrom: nil)).isEmpty)
  }

  @Test func shouldCloseOnlyMonthsStartingOnOrAfterTheScoredFromDayAndTheBudgetsFirstWholeMonth() {
    let starts = { (book: BudgetBook) in Self.closable(book).map(\.period.start) }
    let september = MoneyReadsFixture.date("2026-09-01")
    #expect(starts(Self.book(scoredFrom: "2026-09-01")) == [september, Self.october], "every ended month, oldest first")
    #expect(starts(Self.book(scoredFrom: "2026-09-02")) == [Self.october], "scored from mid-September")
    #expect(starts(Self.book(budgets: [F.home(createdOn: "2026-09-02")], scoredFrom: "2026-09-01")) == [Self.october], "created mid-September")
    #expect(starts(Self.book(budgets: [F.home(createdOn: "2026-10-01")], scoredFrom: "2026-09-01")) == [Self.october], "created on October's first day")
    #expect(starts(Self.book(budgets: [F.home(createdOn: "2026-10-02")])).isEmpty)
    #expect(Self.closable(Self.book(), today: MoneyReadsFixture.date("2026-11-03"), now: Self.millis("2026-11-03", hour: 23)).isEmpty, "October's grace is not over")
  }

  @Test func shouldCloseOnlyLiveBudgetsWithALimitThatReplayHasNotClosed() {
    let usd = F.monthly(1, F.usd, limitMinor: 50_000, createdOn: "2026-07-01")
    let unlimited = F.monthly(2, F.gbp, limitMinor: nil, createdOn: "2026-07-01")
    let removed = F.monthly(3, F.jpy, limitMinor: 50_000, createdOn: "2026-07-01")
    let dollars = [F.expense(200, 1_000, F.usd, on: "2026-10-04")]
    let book = Self.book(budgets: [F.home(createdOn: "2026-07-01"), usd, unlimited], removed: [removed], expenses: Self.spending + dollars)
    #expect(Self.closable(book).map(\.budget.id) == [HomeBudget.id, usd.id])

    let closed = Self.book(
      budgets: [F.home(createdOn: "2026-07-01"), usd], expenses: Self.spending + dollars, closes: [MoneyCloseKey(budget: HomeBudget.id, periodStart: Self.october): 1])
    #expect(Self.closable(closed).map(\.budget.id) == [usd.id])
    #expect(Self.closable(Self.book(budgets: [F.home(limitMinor: nil, createdOn: "2026-07-01")])).isEmpty, "Home without a limit")
    #expect(Self.closable(Self.book(budgets: [])).isEmpty, "Home not written yet stands in from today")
  }

  @Test func shouldOrderClosesByPeriodThenByBudget() {
    let usd = F.monthly(1, F.usd, limitMinor: 50_000, createdOn: "2026-07-01")
    let dollars = [F.expense(200, 1_000, F.usd, on: "2026-09-04"), F.expense(201, 1_000, F.usd, on: "2026-10-04")]
    let closes = Self.closable(Self.book(budgets: [usd, F.home(createdOn: "2026-07-01")], expenses: Self.spending + dollars, scoredFrom: "2026-09-01"))
    #expect(closes.map(\.key.budget) == [HomeBudget.id, usd.id, HomeBudget.id, usd.id])
    #expect(closes.map(\.period.start.month) == [9, 9, 10, 10])
  }

  @Test func shouldScoreAPeriodOnlyWhenSixtyPercentOfItsDaysAreCovered() throws {
    let scored = try #require(Self.october(Self.book(covered: Self.days("2026-10", 19))))
    #expect(scored.coverage == LoggingCoverage(coveredDays: 19, daysSoFar: 31))
    #expect(scored.outcome == .withinTypical)
    let unscored = try #require(Self.october(Self.book(covered: Self.days("2026-10", 18))))
    #expect(unscored.outcome == .unscored && unscored.deposit == .skipped(.overOrUnscored) && !unscored.deposited)
  }

  @Test func shouldScoreAThirtyDayMonthAtExactlySixtyPercentCoverage() throws {
    let september = MoneyReadsFixture.date("2026-09-01")
    let judged = { (covered: Int) in
      Self.closable(Self.book(covered: Self.days("2026-09", covered), scoredFrom: "2026-09-01")).first { $0.period.start == september }
    }
    let scored = try #require(judged(18))
    #expect(scored.coverage == LoggingCoverage(coveredDays: 18, daysSoFar: 30) && scored.outcome == .within)
    #expect(judged(17)?.outcome == .unscored)
  }

  @Test func shouldNeverCloseAnotherBudgetsPeriodWithoutAnExpenseCounted() {
    let usd = F.monthly(1, F.usd, limitMinor: 50_000, createdOn: "2026-07-01")
    let trip = BudgetRecord(
      id: F.id(7), name: "Trip", currency: F.eur, limitMinor: 50_000,
      period: .trip(from: MoneyReadsFixture.date("2026-10-10"), through: MoneyReadsFixture.date("2026-10-20")), createdOn: MoneyReadsFixture.date("2026-10-09"))
    let budgets = [F.home(createdOn: "2026-07-01"), usd, trip]
    let quiet = Self.book(budgets: budgets, expenses: Self.spending)
    #expect(Self.closable(quiet).map(\.budget.id) == [HomeBudget.id], "a month without dollars and a trip without spending are not judged")

    let excluded = Self.book(
      budgets: budgets,
      expenses: Self.history + [F.expense(1, 2_000, F.gbp, on: "2026-10-03", budget: usd.id), F.expense(2, 3_000, MoneyReadsFixture.currency("ZZZ"), on: "2026-10-12")])
    #expect(
      Self.closable(excluded, now: Self.millis("2026-11-11")).map(\.budget.id) == [HomeBudget.id],
      "the dollar budget's pounds still wait for a rate after the hold, the trip's expense never converts; Home closes with nothing counted")
  }

  @Test func shouldCloseAHomeMonthWithNothingLoggedAsUnscored() throws {
    let unlogged = try #require(Self.october(Self.book(expenses: Self.history, covered: [])))
    #expect(unlogged.outcome == .unscored && unlogged.spentMinor == 0 && unlogged.deposit == .skipped(.overOrUnscored))
  }

  @Test func shouldDepositTheWholeReferenceForAHomeMonthOfNoSpend() throws {
    let quiet = try #require(Self.october(Self.book(expenses: Self.history, covered: Self.wholeOctober)))
    #expect(quiet.outcome == .withinTypical && quiet.spentMinor == 0)
    #expect(quiet.deposit == .amount(66_000, rate: nil), "the typical 60 000 times 1.1, under the limit")
  }

  @Test func shouldNeverMakeAnUnloggedHomeMonthCheaperThanAnOverspentOne() throws {
    let rules = Ruleset.current.money ?? .v2
    let unlogged = try #require(Self.october(Self.book(expenses: Self.history, covered: [])))
    for spent: Int64 in [100_001, 110_000, 110_001, 125_000, 125_001, 300_000] {
      let overspent = try #require(Self.october(Self.book(expenses: Self.history + [F.expense(1, spent, on: "2026-10-05")])))
      for mode in [IntensityMode.standard, .lowIntensity, .highIntensity] {
        guard case .penalty(let unloggedFine, let unloggedDebuff) = rules.close[mode][unlogged.outcome],
          case .penalty(let overFine, let overDebuff) = rules.close[mode][overspent.outcome]
        else { throw MemoirFixtureError(description: "both are penalised") }
        #expect(unloggedFine >= overFine, "\(spent) under \(mode)")
        #expect(unloggedDebuff.multiplier <= overDebuff.multiplier && unloggedDebuff.days >= overDebuff.days, "\(spent) under \(mode)")
      }
      #expect(unlogged.deposit.amountMinor == 0 && overspent.deposit.amountMinor == 0)
    }
  }

  @Test func shouldCloseNothingWhileReplayIsHalted() {
    let book = Self.book()
    let halted = BudgetBook(
      settings: book.settings, assignments: book.assignments, rates: book.rates, coveredDays: book.coveredDays, closeInstants: [:], zone: book.zone,
      replayHalt: .unknownCommandType(command: MemoirStoreFixture.commandID(1), type: "future.feature"))
    #expect(!Self.closable(book).isEmpty)
    #expect(Self.closable(halted).isEmpty)
  }

  @Test func shouldKeepAPeriodClosedWhoseCloseCommandCannotBeRead() throws {
    let book = Self.book(expenses: Self.spending + [F.expense(1, 4_000, on: "2026-10-31", loggedOn: "2026-11-05")])
    let key = MoneyCloseKey(budget: HomeBudget.id, periodStart: Self.october)
    let unreadable = BudgetBook(
      settings: book.settings, assignments: book.assignments, rates: book.rates, coveredDays: book.coveredDays, closeInstants: [:], closedPeriods: [key],
      zone: book.zone)
    #expect(Self.october(unreadable) == nil, "closed, so never closed again")
    let home = try #require(unreadable.liveBudgets(today: F.today).first)
    let october = try #require(home.period(containing: Self.october))
    #expect(unreadable.cutoffMillis(of: HomeBudget.id, period: october) == unreadable.earliestCloseMillis(of: october))
    let november = try #require(home.period(containing: F.today))
    let month = try #require(unreadable.history(of: home, before: november, today: F.today)?.months.last)
    #expect(month.isClosed && month.spentMinor == 1_000)
  }

  @Test func shouldTierAnOverspendAtTenAndTwentyFivePercentOfTheLimit() {
    let full = LoggingCoverage(coveredDays: 30, daysSoFar: 30)
    let outcome = { (spent: Int64, limit: Int64) in
      BudgetCloseReads.outcome(spentMinor: spent, limitMinor: limit, coverage: full, typicalMonthMinor: nil, drewOnSavings: false)
    }
    #expect(outcome(100_000, 100_000) == .within)
    #expect(outcome(110_000, 100_000) == .over10)
    #expect(outcome(110_001, 100_000) == .over25)
    #expect(outcome(125_000, 100_000) == .over25)
    #expect(outcome(125_001, 100_000) == .overMore)
    #expect(outcome(1, 0) == .overMore, "anything over a zero limit")
    #expect(outcome(0, 0) == .within)
    #expect(
      BudgetCloseReads.outcome(
        spentMinor: 200_000, limitMinor: 100_000, coverage: LoggingCoverage(coveredDays: 17, daysSoFar: 30), typicalMonthMinor: nil, drewOnSavings: false)
        == .unscored, "unscored before over")
    #expect(
      BudgetCloseReads.outcome(
        spentMinor: 1, limitMinor: 100_000, coverage: LoggingCoverage(coveredDays: 18, daysSoFar: 30), typicalMonthMinor: nil, drewOnSavings: false) == .within,
      "exactly 600 thousandths is scored")
  }

  @Test func shouldRewardTheTypicalTierOnlyAfterCalibrationWithoutASavingsDraw() throws {
    let typical = try #require(Self.october(Self.book(expenses: Self.history + [F.expense(1, 60_000, on: "2026-10-05")])))
    #expect(typical.outcome == .withinTypical && typical.typicalMonthMinor == 60_000)
    #expect(Self.october(Self.book(expenses: Self.history + [F.expense(1, 60_001, on: "2026-10-05")]))?.outcome == .within)

    let calibrating = try #require(
      Self.october(Self.book(budgets: [F.home(createdOn: "2026-09-01")], expenses: Self.history + [F.expense(1, 1_000, on: "2026-10-05")])))
    #expect(calibrating.outcome == .within && calibrating.typicalMonthMinor == nil && calibrating.deposit == .skipped(.calibrating))

    let drew = try #require(Self.october(Self.book(expenses: Self.history + [F.expense(1, 70_000, on: "2026-10-05", fromSavingsMinor: 30_000)])))
    #expect(drew.spentMinor == 40_000, "the savings part is not the budget's")
    #expect(drew.outcome == .within, "a month that drew on savings earns at most the base tier")
    #expect(drew.deposit == .amount(26_000, rate: nil), "it still deposits what it left of the reference")
  }

  @Test func shouldDepositTheReferenceLessSpendingInAMonthWithinItsLimit() throws {
    let deposit = { (spent: Int64, budgets: [BudgetRecord]) in
      Self.october(Self.book(budgets: budgets, expenses: Self.history + [F.expense(1, spent, on: "2026-10-05")]))?.deposit
    }
    let home = [F.home(createdOn: "2026-07-01")]
    #expect(deposit(50_000, home) == .amount(16_000, rate: nil), "the typical month times 1.1, 66 000, under the limit")
    #expect(deposit(66_000, home) == .skipped(.reachedReference))
    #expect(deposit(90_000, home) == .skipped(.reachedReference), "within the limit, over the reference")
    #expect(deposit(120_000, home) == .skipped(.overOrUnscored))
    #expect(deposit(10_000, [F.home(limitMinor: 62_000, createdOn: "2026-07-01")]) == .amount(52_000, rate: nil), "the limit caps the reference")

    let closable = try #require(Self.october(Self.book(expenses: Self.history + [F.expense(1, 50_000, on: "2026-10-05")])))
    #expect(closable.deposited && closable.deposit.amountMinor == 16_000)
    let command = MemoirStoreFixture.commandID(9)
    #expect(
      closable.snapshot(command: command)
        == SavingsDeposit(
          amountMinor: 16_000, currency: F.eur, closedOn: F.today, command: command, spentMinor: 50_000, limitMinor: 100_000, medianExpenseMinor: 50_000))
  }

  @Test func shouldConvertAForeignBudgetsDepositAtItsNewestRateOnOrBeforeTheCloseDay() throws {
    let usd = F.monthly(1, F.usd, limitMinor: 100_000, createdOn: "2026-07-01")
    let expenses = [
      F.expense(101, 50_000, F.usd, on: "2026-07-10"), F.expense(102, 60_000, F.usd, on: "2026-08-10"), F.expense(103, 70_000, F.usd, on: "2026-09-10"),
      F.expense(1, 50_001, F.usd, on: "2026-10-05"),
    ]
    let rates = [
      MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-01", "0.5"), MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-20", "0.9"),
      MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-22", "2"),
    ]
    let closable = try #require(Self.october(Self.book(budgets: [F.home(createdOn: "2026-07-01"), usd], expenses: expenses, rates: rates), budget: usd.id))
    #expect(closable.deposit == .amount(14_399, rate: MoneyReadsFixture.decimal("0.9")), "15 999 dollar cents at 0.9, halves up")
    #expect(closable.snapshot(command: MemoirStoreFixture.commandID(1)).rate == MoneyReadsFixture.decimal("0.9"))
    #expect(closable.snapshot(command: MemoirStoreFixture.commandID(1)).currency == F.eur)
  }

  @Test func shouldHoldAForeignDepositWithoutARateThenDepositNothing() throws {
    let usd = F.monthly(1, F.usd, limitMinor: 100_000, createdOn: "2026-07-01")
    let expenses = [
      F.expense(101, 50_000, F.usd, on: "2026-07-10"), F.expense(102, 60_000, F.usd, on: "2026-08-10"), F.expense(103, 70_000, F.usd, on: "2026-09-10"),
      F.expense(1, 10_000, F.usd, on: "2026-10-05"),
    ]
    let book = Self.book(budgets: [F.home(createdOn: "2026-07-01"), usd], expenses: expenses)
    #expect(Self.october(book, budget: usd.id, now: Self.millis("2026-11-10", hour: 12)) == nil)
    let closable = try #require(Self.october(book, budget: usd.id, now: Self.millis("2026-11-11")))
    #expect(closable.deposit == .skipped(.rateMissing) && !closable.deposited && closable.outcome == .withinTypical)
    #expect(closable.snapshot(command: MemoirStoreFixture.commandID(1)).amountMinor == 0)
  }

  @Test func shouldCloseATripOnceWithinOrOverWithoutADeposit() throws {
    let trip = BudgetRecord(
      id: F.id(7), name: "Trip", currency: F.eur, limitMinor: 50_000,
      period: .trip(from: MoneyReadsFixture.date("2026-10-10"), through: MoneyReadsFixture.date("2026-10-20")), createdOn: MoneyReadsFixture.date("2026-10-12"))
    let covered = Self.days("2026-10", 31)
    let within = Self.book(budgets: [F.home(createdOn: "2026-07-01"), trip], expenses: Self.history + [F.expense(1, 100, on: "2026-10-11")], covered: covered)
    #expect(Self.closable(within, now: Self.millis("2026-10-24") - 1).isEmpty)
    let closes = Self.closable(within, today: MoneyReadsFixture.date("2026-10-24"), now: Self.millis("2026-10-24"))
    let closed = try #require(closes.first { $0.budget.id == trip.id })
    #expect(closed.outcome == .within && closed.typicalMonthMinor == nil, "no typical tier for a trip")
    #expect(closed.deposit == .skipped(.trip) && closed.coverage == LoggingCoverage(coveredDays: 11, daysSoFar: 11))

    let over = Self.book(budgets: [F.home(createdOn: "2026-07-01"), trip], expenses: [F.expense(1, 55_000, on: "2026-10-11")])
    #expect(Self.closable(over).first { $0.budget.id == trip.id }?.outcome == .over10)

    var late = trip
    late.createdOn = MoneyReadsFixture.date("2026-10-14")
    #expect(!Self.closable(Self.book(budgets: [late])).contains { $0.budget.id == trip.id }, "more than three days backdated")
    #expect(!Self.closable(Self.book(budgets: [trip], scoredFrom: "2026-10-11")).contains { $0.budget.id == trip.id }, "started before money was scored")
  }

  @Test func shouldFreezeTheSameSpendingLimitAndMedianTheHistoryReadsForTheLoggedMonth() throws {
    let book = Self.book(
      expenses: Self.history + [
        F.expense(1, 3_000, on: "2026-10-02"), F.expense(2, 5_000, on: "2026-10-12"), F.expense(3, 8_000, on: "2026-10-20", fromSavingsMinor: 2_000),
        F.expense(4, 9_000, on: "2026-10-31", loggedOn: "2026-11-05"),
      ])
    let home = try #require(book.liveBudgets(today: F.today).first)
    let november = try #require(home.period(containing: F.today))
    let logged = try #require(book.history(of: home, before: november, today: F.today)?.months.last)
    let closable = try #require(Self.october(book))
    #expect(closable.spentMinor == logged.spentMinor && closable.spentMinor == 14_000)
    #expect(closable.limitMinor == logged.limitMinor && closable.medianExpenseMinor == logged.medianExpenseMinor && logged.medianExpenseMinor == 5_000)

    let snapshot = closable.snapshot(command: MemoirStoreFixture.commandID(1))
    let frozen = Self.book(expenses: book.assignments.expenses, deposits: [closable.key: snapshot])
    let read = try #require(frozen.history(of: home, before: november, today: F.today)?.months.last)
    #expect(read.source == .closeSnapshot(snapshot))
    #expect(read.spentMinor == logged.spentMinor && read.limitMinor == logged.limitMinor && read.medianExpenseMinor == logged.medianExpenseMinor)
  }

  @Test func shouldJudgeAPeriodWhoseDepositArrivedWithoutItsCloseFromTheDepositsSnapshot() throws {
    let recorded = SavingsDeposit(
      amountMinor: 4_000, currency: F.eur, closedOn: MoneyReadsFixture.date("2026-11-05"), command: MemoirStoreFixture.commandID(3), spentMinor: 62_000,
      limitMinor: 100_000, medianExpenseMinor: 31_000)
    let book = Self.book(
      expenses: Self.history + [F.expense(1, 10_000, on: "2026-10-05"), F.expense(2, 3_000, F.usd, on: "2026-10-06")],
      deposits: [MoneyCloseKey(budget: HomeBudget.id, periodStart: Self.october): recorded])
    let closable = try #require(Self.october(book, now: Self.millis("2026-11-04")), "the snapshot is final: no hold")
    #expect(closable.deposit == .recorded(recorded) && closable.deposited)
    #expect(closable.spentMinor == 62_000 && closable.outcome == .within && closable.medianExpenseMinor == 31_000)
    #expect(closable.excluded == .none)
    #expect(closable.snapshot(command: MemoirStoreFixture.commandID(9)) == recorded)
  }
}
