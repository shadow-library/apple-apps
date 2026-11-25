import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget standings", TestTimeLimit.standard)
struct BudgetStandingsTests {
  private typealias F = BudgetStandingsFixture

  private static func spending(_ minor: Int64, on today: String = "2026-11-21") throws -> BudgetPeriodStanding {
    try F.home(F.book(expenses: [F.expense(1, minor, on: "2026-11-01")]), today: MoneyReadsFixture.date(today))
  }

  @Test func shouldReadEveryPaceStateAtItsBoundaries() throws {
    let cases: [(spent: Int64, today: String, pace: BudgetPace)] = [
      (70_000, "2026-11-21", .onTrack),
      (70_001, "2026-11-21", .atRisk(.projectedOver)),
      (79_999, "2026-11-30", .onTrack),
      (80_000, "2026-11-30", .atRisk(.mostlySpent)),
      (100_000, "2026-11-21", .atRisk(.mostlySpent)),
      (100_001, "2026-11-21", .over(byMinor: 1)),
    ]
    for item in cases {
      #expect(try Self.spending(item.spent, on: item.today).pace == item.pace, "\(item.spent) by \(item.today)")
    }
    let projected = try Self.spending(70_001)
    #expect(projected.projectedMinor == 100_001, "70,001 over 21 of 30 days ends at 100,001.43")
    #expect(projected.leftMinor == 29_999)
  }

  @Test func shouldSpreadWhatIsLeftOverTheDaysLeftAndStopOnceOver() throws {
    #expect(try Self.spending(70_000).safePerDayMinor == 3_000, "30,000 over the 10 days left, today included")
    #expect(try Self.spending(70_001).safePerDayMinor == 2_999, "rounded down, so spending it never goes over")
    #expect(try Self.spending(79_999, on: "2026-11-30").safePerDayMinor == 20_001, "the last day holds everything left")
    #expect(try Self.spending(100_000).safePerDayMinor == 0)
    #expect(try Self.spending(100_001).safePerDayMinor == nil)
    let standing = try Self.spending(0)
    #expect(standing.phase == .current(daysElapsed: 21, daysLeft: 10))
    #expect(standing.period.span == DateSpan.month(of: F.today))
  }

  @Test func shouldStandABudgetWithoutALimitApart() throws {
    let home = try F.home(F.book(budgets: [F.home(limitMinor: nil)], expenses: [F.expense(1, 4_000, on: "2026-11-02")]))
    #expect(home.pace == .noLimit)
    #expect(home.limitMinor == nil && home.leftMinor == nil && home.safePerDayMinor == nil)
    #expect(home.spend.spentMinor == 4_000)
    #expect(home.oneOff == .unavailable)
    #expect(home.history?.typical == .calibrating(completeMonths: 0))

    let zero = try F.home(F.book(budgets: [F.home(limitMinor: 0)]))
    #expect(zero.pace == .onTrack, "nothing spent against a zero limit")
  }

  @Test func shouldStandATripBeforeDuringAndAfterItsDates() throws {
    let trip = F.trip(2, F.usd, limitMinor: 50_000, from: "2026-12-01", through: "2026-12-10")
    let book = F.book(
      budgets: [F.home(), trip], expenses: [F.expense(1, 1_000, F.usd, on: "2026-12-02")], covered: ["2026-11-30", "2026-12-01", "2026-12-03"])

    let upcoming = try #require(try F.standings(book).standing(of: trip.id))
    #expect(upcoming.phase == .upcoming(startsInDays: 10))
    #expect(upcoming.spend.spentMinor == 1_000, "an expense dated inside the trip counts before it starts")
    #expect(upcoming.safePerDayMinor == 4_900, "what is left over the whole trip")
    #expect(upcoming.projectedMinor == nil && upcoming.pace == .onTrack)
    #expect(upcoming.coverage == LoggingCoverage(coveredDays: 0, daysSoFar: 0))
    #expect(upcoming.history == nil)
    #expect(upcoming.oneOff == .limitShare(5_000), "a trip never has a typical month")

    let active = try #require(try F.standings(book, today: MoneyReadsFixture.date("2026-12-03")).standing(of: trip.id))
    #expect(active.phase == .current(daysElapsed: 3, daysLeft: 8))
    #expect(active.coverage == LoggingCoverage(coveredDays: 2, daysSoFar: 3))
    #expect(active.safePerDayMinor == 6_125)

    let ended = try #require(try F.standings(book, today: MoneyReadsFixture.date("2026-12-15")).standing(of: trip.id))
    #expect(ended.phase == .ended)
    #expect(ended.safePerDayMinor == nil)
    #expect(ended.projectedMinor == 1_000)
    #expect(ended.coverage == LoggingCoverage(coveredDays: 2, daysSoFar: 10))
  }

  @Test func shouldCountForeignExpensesWaitingOrUnconvertibleApartAndOverflowAsUnconvertible() throws {
    let unknown = try #require(CurrencyCode("ZZZ"))
    let home = try F.home(
      F.book(expenses: [
        F.expense(1, Int64.max - 10, on: "2026-11-02"), F.expense(2, 5_000, F.usd, on: "2026-11-03"), F.expense(3, 100, on: "2026-11-04"),
        F.expense(4, 700, unknown, on: "2026-11-05"),
      ]))
    #expect(home.spend.spentMinor == Int64.max - 10)
    #expect(home.spend.counted == 1)
    #expect(home.spend.pending == PendingConversions(awaitingRate: 1, unconvertible: 2, currencies: [F.usd]))
    #expect(home.pace == .over(byMinor: Int64.max - 100_010))
  }

  @Test func shouldLeaveTheSavingsPartOutAndConvertOnlyThePartCounted() throws {
    let rate = MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-06", "0.9")
    let home = try F.home(
      F.book(
        expenses: [
          F.expense(1, 10_000, on: "2026-11-02", fromSavingsMinor: 4_000), F.expense(2, 3_000, on: "2026-11-03", fromSavingsMinor: 9_000),
          F.expense(3, 10_000, F.usd, on: "2026-11-04", fromSavingsMinor: 10_000), F.expense(4, 2_000, F.usd, on: "2026-11-06", fromSavingsMinor: 1_000),
        ], rates: [rate]))
    #expect(home.spend.spentMinor == 6_000 + 900, "a savings part above the amount is clamped to it")
    #expect(home.spend.pending == .none, "an expense drawn wholly on savings needs no rate")
    #expect(home.spend.drewOnSavings)
    #expect(try !F.home(F.book(expenses: [F.expense(1, 10_000, on: "2026-11-02")])).spend.drewOnSavings)
  }

  @Test func shouldReadLoggingCoverageOnlyFromReplaysCoveredDays() throws {
    let home = try F.home(F.book(covered: ["2026-10-31", "2026-11-01", "2026-11-05", "2026-11-21"]))
    #expect(home.coverage == LoggingCoverage(coveredDays: 3, daysSoFar: 21))
    let logged = try F.home(F.book(expenses: [F.expense(1, 1_000, on: "2026-11-02")]))
    #expect(logged.coverage.coveredDays == 0, "an expense record alone covers nothing; only replay does")
  }

  /// Aug 30,000; Sep 50,000 plus 1,000 logged before its close and 500 after; Oct 40,000 plus 2,000 logged within the grace and 5,000 back-dated after it.
  private static func history(
    closes: [MoneyCloseKey: Int64] = [:], deposits: [MoneyCloseKey: SavingsDeposit] = [:], zone: AccountZone = .unset, createdOn: String = "2026-07-15"
  ) -> BudgetBook {
    F.book(
      budgets: [F.home(createdOn: createdOn)],
      expenses: [
        F.expense(1, 30_000, on: "2026-08-10"), F.expense(2, 50_000, on: "2026-09-10"), F.expense(3, 1_000, on: "2026-09-28", loggedOn: "2026-10-05"),
        F.expense(4, 500, on: "2026-09-29", loggedOn: "2026-10-07"), F.expense(5, 40_000, on: "2026-10-10"),
        F.expense(6, 2_000, on: "2026-10-31", loggedOn: "2026-11-03"), F.expense(7, 5_000, on: "2026-10-20", loggedOn: "2026-11-10"),
        F.expense(8, 9_000, on: "2026-07-20"),
      ], closes: closes, deposits: deposits, zone: zone)
  }

  @Test func shouldTakeTheTypicalMonthFromExpensesLoggedBeforeEachMonthsCutoff() throws {
    let september = MoneyCloseKey(budget: HomeBudget.id, periodStart: MoneyReadsFixture.date("2026-09-01"))
    let closedAt = MoneyReadsFixture.millis(MoneyReadsFixture.date("2026-10-06"))
    let history = try #require(try F.home(Self.history(closes: [september: closedAt])).history)
    #expect(history.months.map(\.period.start.isoString) == ["2026-08-01", "2026-09-01", "2026-10-01"], "July, when the budget was created, is partial")
    #expect(history.months.map(\.spentMinor) == [30_000, 51_000, 42_000])
    #expect(history.months.map(\.isClosed) == [false, true, false])
    #expect(Self.cutoff(history.months[1]) == closedAt, "a closed month counts what was logged before its close")
    #expect(Self.cutoff(history.months[2]) == MoneyReadsFixture.millis(MoneyReadsFixture.date("2026-11-04"), hour: 0), "else the end of its third grace day")
    #expect(history.months.map(\.medianExpenseMinor) == [30_000, 25_500, 21_000], "each month's own median, halves up")
    #expect(history.typical == .known(monthMinor: 42_000, singleExpenseMinor: 25_500), "the median of the months' medians")

    let unclosed = try #require(try F.home(Self.history()).history)
    #expect(unclosed.months.map(\.spentMinor) == [30_000, 50_000, 42_000], "logged after the grace and no close: left out")

    let auckland = AccountZone(inForce: "Pacific/Auckland", openDay: F.today, lastRecordedOffsetMinutes: 780, staged: nil)
    let zoned = try #require(try F.home(Self.history(zone: auckland)).history)
    #expect(zoned.months.last?.spentMinor == 40_000, "the grace ends at midnight in the account's zone, 11:00 UTC on Nov 3")
  }

  private static func cutoff(_ month: RecordedMonth) -> Int64? {
    guard case .logged(let cutoff, _) = month.source else { return nil }
    return cutoff
  }

  @Test func shouldTakeAClosedMonthsSpendingAndLimitFromItsDepositRecord() throws {
    let september = MoneyCloseKey(budget: HomeBudget.id, periodStart: MoneyReadsFixture.date("2026-09-01"))
    let closedAt = MoneyReadsFixture.millis(MoneyReadsFixture.date("2026-10-06"))
    let deposit = SavingsDeposit(
      amountMinor: 0, currency: F.eur, closedOn: MoneyReadsFixture.date("2026-10-06"), command: MemoirStoreFixture.commandID(1), spentMinor: 45_000, limitMinor: 90_000,
      medianExpenseMinor: 20_000)
    let history = try #require(try F.home(Self.history(closes: [september: closedAt], deposits: [september: deposit])).history)
    #expect(history.months[1].source == .closeSnapshot(deposit))
    #expect(history.months[1].isClosed)
    #expect(history.months.map(\.spentMinor) == [30_000, 45_000, 42_000], "the 51,000 the expenses now add up to never replaces what the close judged")
    #expect(history.months.map(\.limitMinor) == [100_000, 90_000, 100_000])
    #expect(history.typical == .known(monthMinor: 42_000, singleExpenseMinor: 21_000), "medians 30,000, 20,000 from the deposit, 21,000")
  }

  @Test func shouldKeepAClosedMonthsMedianExpenseWhateverIsEditedAfterItsClose() throws {
    let september = MoneyCloseKey(budget: HomeBudget.id, periodStart: MoneyReadsFixture.date("2026-09-01"))
    let closedAt = MoneyReadsFixture.millis(MoneyReadsFixture.date("2026-10-06"))
    let deposit = SavingsDeposit(
      amountMinor: 0, currency: F.eur, closedOn: MoneyReadsFixture.date("2026-10-06"), command: MemoirStoreFixture.commandID(1), spentMinor: 51_000, limitMinor: 100_000,
      medianExpenseMinor: 25_500)
    let august = F.expense(1, 30_000, on: "2026-08-10")
    let october = [F.expense(5, 40_000, on: "2026-10-10"), F.expense(6, 2_000, on: "2026-10-31", loggedOn: "2026-11-03")]
    let asClosed = [august, F.expense(2, 50_000, on: "2026-09-10"), F.expense(3, 1_000, on: "2026-09-28", loggedOn: "2026-10-05")] + october
    let edited = [august, F.expense(3, 0, on: "2026-09-28", loggedOn: "2026-10-05"), F.expense(9, 100, on: "2026-09-15", budget: HomeBudget.id)] + october
    let home = [F.home(createdOn: "2026-07-15")]
    let before = try F.home(F.book(budgets: home, expenses: asClosed, closes: [september: closedAt], deposits: [september: deposit]))
    let after = try F.home(F.book(budgets: home, expenses: edited, closes: [september: closedAt], deposits: [september: deposit]))
    #expect(before.oneOff == .typicalExpense(255_000))
    #expect(after.oneOff == before.oneOff, "deleting the 50,000, refunding the 1,000 and moving in a 100 leave the closed month's median as closed")
    let unfrozen = try F.home(F.book(budgets: home, expenses: edited, closes: [september: closedAt]))
    #expect(unfrozen.oneOff == .typicalExpense(210_000), "without the deposit's snapshot the edits would lower the threshold")
  }

  @Test func shouldCalibrateUntilTwoCompleteMonths() throws {
    let one = try F.home(Self.history(createdOn: "2026-09-10"))
    #expect(one.history?.months.count == 1)
    #expect(one.history?.typical == .calibrating(completeMonths: 1))
    #expect(one.oneOff == .limitShare(10_000), "10% of the limit while calibrating")

    let two = try F.home(Self.history(createdOn: "2026-09-01"))
    #expect(two.history?.typical == .known(monthMinor: 46_000, singleExpenseMinor: 35_500), "created on the first, September counts whole")

    let none = try F.home(Self.history(createdOn: "2026-11-05"))
    #expect(none.history?.typical == .calibrating(completeMonths: 0))
  }

  @Test func shouldPreferTheOwnersOneOffThresholdThenTheTypicalExpenseThenTheLimit() throws {
    let owner = try F.home(F.book(budgets: [F.home(createdOn: "2026-07-15", oneOffFromMinor: 7_777)], expenses: Self.history().assignments.expenses))
    #expect(owner.oneOff == .owner(7_777))
    #expect(try F.home(Self.history()).oneOff == .typicalExpense(300_000), "ten times the median of the monthly medians 30,000, 50,000 and 21,000")
    let quiet = try F.home(F.book(budgets: [F.home(createdOn: "2026-07-15")]))
    #expect(quiet.history?.typical == .known(monthMinor: 0, singleExpenseMinor: nil))
    #expect(quiet.oneOff == .limitShare(10_000), "no expense to take a median of")
    #expect(quiet.oneOff.minor == 10_000)
  }

  @Test func shouldReadTheHistoryBeforeAnyPeriodForACloseToJudge() throws {
    let book = Self.history()
    let home = try F.home(book).budget
    let october = try #require(home.period(containing: MoneyReadsFixture.date("2026-10-15")))
    let history = try #require(book.history(of: home, before: october, today: F.today))
    #expect(history.months.map(\.period.start.isoString) == ["2026-08-01", "2026-09-01"], "a month never judges itself")
    #expect(book.oneOffThreshold(of: home, on: MoneyReadsFixture.date("2026-10-15"), today: F.today) == .typicalExpense(400_000))
  }

  @Test func shouldJudgeAFutureDatedExpenseOnlyByWhatHoldsToday() throws {
    let december = MoneyReadsFixture.date("2026-12-15")
    let book = Self.history()
    let home = try F.home(book).budget
    #expect(book.oneOffThreshold(of: home, on: december, today: F.today) == .typicalExpense(300_000), "November has not ended, so it is not a month yet")
    #expect(book.history(of: home, before: try #require(home.period(containing: december)), today: F.today)?.months.last?.period.start.isoString == "2026-10-01")

    var staged = F.home(createdOn: "2026-07-15", oneOffFromMinor: 50_000)
    staged.stagedOneOff = StagedAmount(amountMinor: 20_000, from: MoneyReadsFixture.date("2026-12-01"))
    let lowering = F.book(budgets: [staged])
    let owner = try F.home(lowering).budget
    #expect(lowering.oneOffThreshold(of: owner, on: december, today: F.today) == .owner(50_000), "a staged lowering waits for its day, whatever the expense's date")
  }

  @Test func shouldConsolidateRunningBudgetsInTheHomeCurrencyAtTheLatestRates() throws {
    let gbp = F.monthly(3, F.gbp, limitMinor: 50_000)
    let jpy = F.monthly(4, F.jpy, limitMinor: 1_000_000)
    let trip = F.trip(5, F.usd, limitMinor: 20_000, from: "2026-10-01", through: "2026-10-10")
    let usd = F.monthly(6, F.usd, limitMinor: nil)
    let locked = ExpenseRate(rate: MoneyReadsFixture.decimal("1.2"), date: MoneyReadsFixture.date("2026-11-05"), quote: F.eur)
    let book = F.book(
      budgets: [F.home(), gbp, jpy, trip, usd],
      expenses: [
        F.expense(1, 10_000, on: "2026-11-02"), F.expense(2, 1_000, F.gbp, on: "2026-11-05", rate: locked), F.expense(3, 500, F.usd, on: "2026-11-07"),
        F.expense(4, 300, F.usd, on: "2026-10-05"), F.expense(5, 1_000, F.jpy, on: "2026-11-08"),
      ],
      rates: [
        MoneyReadsFixture.rate("GBP", "EUR", on: "2026-11-10", "1.1"), MoneyReadsFixture.rate("GBP", "EUR", on: "2026-11-25", "1.3"),
        MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-07", "0.9"),
      ])
    let standings = try F.standings(book)
    #expect(standings.standing(of: gbp.id)?.spend.spentMinor == 1_000, "a budget counts its own currency exactly")
    let consolidated = standings.consolidated
    #expect(consolidated.budgets == [HomeBudget.id, gbp.id, jpy.id, usd.id], "the ended trip is not running")
    #expect(consolidated.spend.spentMinor == 10_000 + 1_200 + 450, "spending at its locked or recorded rate")
    #expect(consolidated.spend.pending == PendingConversions(awaitingRate: 1, unconvertible: 0, currencies: [F.jpy]))
    #expect(consolidated.limitMinor == 155_000, "100,000 plus GBP's limit at the rate of Nov 10, never Nov 25's")
    #expect(consolidated.limitsPending == PendingConversions(awaitingRate: 1, unconvertible: 0, currencies: [F.jpy]))
    #expect(consolidated.budgetsWithoutLimit == 1)
    #expect(consolidated.leftMinor == 143_800, "Home's 90,000 and GBP's 53,800 left; the no-limit and pending budgets' spending takes nothing from them")
    #expect(consolidated.isApproximate)

    let plain = try F.standings(F.book(expenses: [F.expense(1, 2_000, on: "2026-11-02")])).consolidated
    #expect(!plain.isApproximate && plain.limitMinor == 100_000 && plain.leftMinor == 98_000)
  }

  @Test func shouldLeaveNoLimitOrLeftWhenNoLimitConvertsAndKeepANoLimitBudgetsSpendingApart() throws {
    let jpy = F.monthly(4, F.jpy, limitMinor: 1_000_000)
    let pending = try F.standings(F.book(budgets: [F.home(limitMinor: nil), jpy], expenses: [F.expense(1, 2_000, on: "2026-11-02")])).consolidated
    #expect(pending.limitMinor == nil && pending.leftMinor == nil)
    #expect(pending.limitsPending == PendingConversions(awaitingRate: 1, unconvertible: 0, currencies: [F.jpy]))
    #expect(pending.budgetsWithoutLimit == 1)
    #expect(pending.spend.spentMinor == 2_000)

    let usd = F.monthly(6, F.usd, limitMinor: nil)
    let beside = try F.standings(
      F.book(
        budgets: [F.home(), usd], expenses: [F.expense(1, 2_000, on: "2026-11-02"), F.expense(2, 500, F.usd, on: "2026-11-07")],
        rates: [MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-07", "0.9")])
    ).consolidated
    #expect(beside.spend.spentMinor == 2_450)
    #expect(beside.limitMinor == 100_000 && beside.leftMinor == 98_000, "the no-limit budget's 450 is not taken from Home's left")
  }

  @Test func shouldCountHomeInItsOwnCurrencyWhenItDiffersFromTheDefault() throws {
    let book = F.book(
      budgets: [F.home(limitMinor: 50_000, currency: F.gbp)], expenses: [F.expense(1, 1_100, on: "2026-11-05")],
      rates: [MoneyReadsFixture.rate("GBP", "EUR", on: "2026-11-05", "1.1")])
    let standings = try F.standings(book)
    #expect(standings.homeBudget?.spend.spentMinor == 1_000, "€11.00 at 1.1 euros a pound")
    #expect(standings.home == F.eur)
    #expect(standings.consolidated.limitMinor == 55_000)
  }

  @Test func shouldStandInForHomeUntilItIsWrittenWithTheAccountsMonthlyBudget() throws {
    let book = F.book(budgets: [], expenses: [F.expense(1, 5_000, on: "2026-11-02")], settings: MoneyReadsFixture.settings(budgetMinor: 20_000))
    let home = try F.home(book)
    #expect(home.limitMinor == 20_000 && home.spend.spentMinor == 5_000 && home.leftMinor == 15_000)
    #expect(home.history?.typical == .calibrating(completeMonths: 0))
    #expect(try BudgetStandings.make(F.book(budgets: []), today: F.today)?.budgets.map(\.id) == [HomeBudget.id])
  }

  @Test func shouldLeaveDeletedBudgetsOutAndFollowOverrides() throws {
    let gbp = F.monthly(3, F.gbp, limitMinor: 50_000)
    let locked = ExpenseRate(rate: MoneyReadsFixture.decimal("1.2"), date: MoneyReadsFixture.date("2026-11-05"), quote: F.eur)
    let deleted = try F.standings(F.book(budgets: [F.home()], removed: [gbp], expenses: [F.expense(1, 1_000, F.gbp, on: "2026-11-05", rate: locked)]))
    #expect(deleted.budgets.map(\.id) == [HomeBudget.id])
    #expect(deleted.homeBudget?.spend.spentMinor == 1_200, "its expenses fall back to Home")

    let moved = try F.standings(
      F.book(
        budgets: [F.home(), gbp], expenses: [F.expense(1, 2_000, on: "2026-11-05", budget: gbp.id)],
        rates: [MoneyReadsFixture.rate("GBP", "EUR", on: "2026-11-05", "1.25")]))
    #expect(moved.standing(of: gbp.id)?.spend.spentMinor == 1_600)
    #expect(moved.homeBudget?.spend.spentMinor == 0)
  }

  @Test func shouldMeasureThePeriodAgainstTheLimitOfItsLastDayAndShowAStagedChange() throws {
    var raised = F.home(limitMinor: 100_000)
    raised.stagedLimit = StagedAmount(amountMinor: 150_000, from: MoneyReadsFixture.date("2026-12-01"))
    let staged = try F.home(F.book(budgets: [raised]))
    #expect(staged.limitMinor == 100_000)
    #expect(staged.pendingLimit == raised.stagedLimit)

    var lowered = F.home(limitMinor: 100_000)
    lowered.stagedLimit = StagedAmount(amountMinor: 60_000, from: MoneyReadsFixture.date("2026-11-01"))
    let applied = try F.home(F.book(budgets: [lowered]))
    #expect(applied.limitMinor == 60_000 && applied.pendingLimit == nil)
  }

  @Test func shouldNotStandBeforeTheVaultHasSettings() throws {
    let empty = BudgetBook(
      settings: nil, assignments: BudgetAssignments(budgets: Budgets(MemoirListing(entries: [], unreadable: 0), settings: nil), expenses: [], subscriptions: [:]),
      rates: [], coveredDays: [], closeInstants: [:], zone: .unset)
    #expect(try BudgetStandings.make(empty, today: F.today) == nil)
  }
}
