import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Savings reads", TestTimeLimit.standard)
struct SavingsReadsTests {
  private typealias S = SavingsFixture

  @Test func shouldCountDepositsLessConvertedWithdrawalsAndSetThePendingOnesApart() throws {
    let book = S.book(
      expenses: [
        S.expense(1, 10_000, on: "2026-11-05", fromSavingsMinor: 4_000), S.expense(2, 1_000, on: "2026-11-06", fromSavingsMinor: 5_000),
        S.expense(3, 20_000, S.usd, on: "2026-11-07", fromSavingsMinor: 20_000),
      ],
      deposits: [S.deposit("2026-08", 30_000), S.deposit("2026-09", 20_000), S.deposit("2026-10", 5_000, currency: S.usd)])
    let balance = try S.overview(book).balance

    #expect(balance.depositedMinor == 50_000)
    #expect(balance.withdrawnMinor == 5_000, "a draw above its expense's amount counts only up to the amount")
    #expect(balance.balanceMinor == 45_000)
    #expect(balance.pendingWithdrawals == PendingConversions(awaitingRate: 1, unconvertible: 0, currencies: [S.usd]))
    #expect(balance.depositsInOtherCurrencies == 1)
    #expect(balance.borrowing == .limit(100_000) && balance.floorMinor == -100_000)
    #expect(balance.availableMinor == 145_000)
    #expect(balance.standing == .saving)
    #expect(try S.overview(book).history.map(\.depositedMinor) == [30_000, 20_000, 0])
  }

  @Test func shouldBorrowDownToHomesLimitAndRepayBeforeAnyGoalFills() throws {
    let book = S.book(
      expenses: [S.expense(1, 50_000, on: "2026-11-05", fromSavingsMinor: 30_000)], deposits: [S.deposit("2026-10", 10_000)],
      goals: [S.goal(1, target: 10_000, rank: "V")])
    let overview = try S.overview(book)

    #expect(overview.balance.balanceMinor == -20_000)
    #expect(overview.balance.standing == .repaying(owedMinor: 20_000))
    #expect(overview.balance.availableMinor == 80_000)
    #expect(overview.allocation.owedMinor == 20_000 && overview.allocation.unallocatedMinor == 0)
    #expect(overview.allocation.active.map(\.shareMinor) == [0])
    #expect(overview.forecasts.first?.state == .repaying(owedMinor: 20_000))
    #expect(overview.forecasts.first?.aheadMinor == 30_000, "the debt comes before the goal")

    let noLimit = try S.overview(
      S.book(budgets: [S.home(limitMinor: nil)], expenses: [S.expense(1, 50_000, on: "2026-11-05", fromSavingsMinor: 30_000)], deposits: [S.deposit("2026-10", 10_000)]))
    #expect(noLimit.balance.borrowing == .noLimit)
    #expect(noLimit.balance.availableMinor == 0, "without a limit nothing can be borrowed")
  }

  @Test func shouldConvertAForeignHomesLimitIntoTheHomeCurrencyForTheFloor() throws {
    let foreign = [S.home(limitMinor: 100_000, currency: S.usd)]
    let converted = try S.overview(S.book(budgets: foreign, rates: [MoneyReadsFixture.rate("USD", "EUR", on: "2026-11-20", "0.9")]))
    #expect(converted.balance.borrowing == .limit(90_000))
    let waiting = try S.overview(S.book(budgets: foreign, deposits: [S.deposit("2026-10", 5_000)]))
    #expect(waiting.balance.borrowing == .awaitingRate)
    #expect(waiting.balance.availableMinor == 5_000, "nothing is borrowed until the limit converts")
  }

  @Test func shouldFillGoalsByRankAndLeaveTheRestUnallocated() throws {
    let goals = [S.goal(3, target: 50_000, rank: "k"), S.goal(1, target: 10_000, rank: "F"), S.goal(2, target: 30_000, rank: "V")]
    let partial = try S.overview(S.book(deposits: [S.deposit("2026-08", 35_000)], goals: goals)).allocation
    #expect(partial.active.map(\.id) == [S.goalID(1), S.goalID(2), S.goalID(3)])
    #expect(partial.active.map(\.shareMinor) == [10_000, 25_000, 0])
    #expect(partial.unallocatedMinor == 0)

    let full = try S.overview(S.book(deposits: [S.deposit("2026-08", 100_000)], goals: goals)).allocation
    #expect(full.active.map(\.shareMinor) == [10_000, 30_000, 50_000])
    #expect(full.unallocatedMinor == 10_000)
    #expect(full.active.map(\.progressThousandths) == [1000, 1000, 1000])
  }

  @Test func shouldOrderGoalsWithTheSameRankById() throws {
    let allocation = try S.overview(
      S.book(deposits: [S.deposit("2026-08", 15_000)], goals: [S.goal(2, target: 10_000, rank: "V"), S.goal(1, target: 10_000, rank: "V")])
    ).allocation
    #expect(allocation.active.map(\.id) == [S.goalID(1), S.goalID(2)])
    #expect(allocation.active.map(\.shareMinor) == [10_000, 5_000])
  }

  @Test func shouldReturnAnAbandonedGoalsShareToThePool() throws {
    let goals = [S.goal(1, target: 10_000, rank: "F"), S.goal(2, target: 30_000, rank: "V", state: .abandoned), S.goal(3, target: 50_000, rank: "k")]
    let allocation = try S.overview(S.book(deposits: [S.deposit("2026-08", 100_000)], goals: goals)).allocation
    #expect(allocation.active.map(\.shareMinor) == [10_000, 50_000])
    #expect(allocation.unallocatedMinor == 40_000)
    #expect(allocation.settled.map(\.id) == [S.goalID(2)] && allocation.settled.first?.shareMinor == 0)
  }

  @Test func shouldDrawAPurchaseFromItsGoalsShareFirstAndReturnTheLeftoverOnceBought() throws {
    let purchase = S.expense(1, 12_000, on: "2026-11-05", fromSavingsMinor: 8_000, goal: S.goalID(1))
    let others = [S.goal(2, target: 30_000, rank: "V"), S.goal(3, target: 50_000, rank: "k")]

    let buying = try S.overview(
      S.book(expenses: [purchase], deposits: [S.deposit("2026-08", 100_000)], goals: [S.goal(1, target: 10_000, rank: "F")] + others)
    ).allocation
    #expect(buying.active.map(\.shareMinor) == [2_000, 30_000, 50_000], "the purchase comes out of its own goal's share")
    #expect(buying.active.first?.drawnMinor == 8_000)
    #expect(buying.unallocatedMinor == 10_000)

    let bought = try S.overview(
      S.book(expenses: [purchase], deposits: [S.deposit("2026-08", 100_000)], goals: [S.goal(1, target: 10_000, rank: "F", state: .bought)] + others)
    ).allocation
    #expect(bought.active.map(\.shareMinor) == [30_000, 50_000])
    #expect(bought.unallocatedMinor == 12_000, "what the bought goal held beyond its purchase returns to the pool")
    #expect(bought.settled.first?.drawnMinor == 8_000 && bought.settled.first?.shareMinor == 0)
  }

  @Test func shouldCountWhatAPurchaseDrewTowardsItsGoalsFill() throws {
    let purchase = S.expense(1, 8_000, on: "2026-11-05", fromSavingsMinor: 8_000, goal: S.goalID(1))
    let goals = [S.goal(1, target: 10_000, rank: "F"), S.goal(2, target: 30_000, rank: "V")]

    let plenty = try S.overview(S.book(expenses: [purchase], deposits: [S.deposit("2026-08", 100_000)], goals: goals))
    let first = try #require(plenty.allocation.active.first)
    #expect(first.shareMinor == 2_000 && first.drawnMinor == 8_000 && first.filledMinor == 10_000)
    #expect(first.remainingMinor == 0 && first.progressThousandths == 1000, "a goal partly bought beside unallocated savings is full")
    #expect(plenty.allocation.unallocatedMinor == 60_000)
    #expect(plenty.forecasts.map(\.state) == [.reached(buyFrom: S.today), .reached(buyFrom: S.today)])
    #expect(plenty.forecasts.map(\.aheadMinor) == [0, 0])

    let short = try S.overview(S.book(expenses: [purchase], deposits: S.steadyDeposits, goals: goals))
    #expect(short.allocation.active.map(\.remainingMinor) == [0, 10_000])
    #expect(short.forecasts.last?.aheadMinor == 10_000, "the part already drawn is not waited for again")
  }

  @Test func shouldRewardOnlyGoalsOfAtLeastAQuarterOfHomesLimit() throws {
    let goals = [S.goal(1, target: 25_000, rank: "F"), S.goal(2, target: 24_999, rank: "V")]
    let limited = try S.overview(S.book(goals: goals))
    #expect(limited.rewards[S.goalID(1)] == .eligible && limited.isRewardEligible(S.goalID(1)))
    #expect(limited.rewards[S.goalID(2)] == .targetBelowMinimum(minimumMinor: 25_000) && !limited.isRewardEligible(S.goalID(2)))

    let unlimited = try S.overview(S.book(budgets: [S.home(limitMinor: nil)], goals: goals))
    #expect(unlimited.rewards[S.goalID(1)] == .homeWithoutLimit)

    let foreign = try S.overview(S.book(budgets: [S.home(limitMinor: 100_000, currency: S.usd)], goals: goals))
    #expect(foreign.rewards[S.goalID(1)] == .limitAwaitingRate)
    let converted = try S.overview(
      S.book(budgets: [S.home(limitMinor: 100_000, currency: S.usd)], rates: [MoneyReadsFixture.rate("USD", "EUR", on: "2026-09-30", "0.9")], goals: goals))
    #expect(converted.rewards[S.goalID(2)] == .eligible, "a quarter of 90 000 is 22 500")
  }

  @Test func shouldTakeWhatAPurchaseDrawsBeyondItsShareFromTheGoalsAfterIt() throws {
    let allocation = try S.overview(
      S.book(
        expenses: [S.expense(1, 15_000, on: "2026-11-05", fromSavingsMinor: 15_000, goal: S.goalID(1))], deposits: [S.deposit("2026-08", 40_000)],
        goals: [S.goal(1, target: 10_000, rank: "F"), S.goal(2, target: 30_000, rank: "V"), S.goal(3, target: 50_000, rank: "k")])
    ).allocation
    #expect(allocation.active.map(\.shareMinor) == [0, 25_000, 0])
    #expect(allocation.unallocatedMinor == 0)

    let lastOverdraws = try S.overview(
      S.book(
        expenses: [S.expense(1, 30_000, on: "2026-11-05", fromSavingsMinor: 30_000, goal: S.goalID(2))], deposits: [S.deposit("2026-08", 40_000)],
        goals: [S.goal(1, target: 20_000, rank: "F"), S.goal(2, target: 10_000, rank: "V")])
    ).allocation
    #expect(lastOverdraws.active.map(\.shareMinor) == [10_000, 0], "never more held than savings have")
  }

  @Test func shouldCompleteAGoalWhoseTargetIsLowered() throws {
    let lowered = try S.overview(S.book(deposits: S.steadyDeposits, goals: [S.goal(1, target: 20_000, rank: "V")]))
    #expect(lowered.allocation.active.first?.remainingMinor == 0)
    #expect(lowered.forecasts.first?.state == .reached(buyFrom: S.today))
    #expect(lowered.allocation.unallocatedMinor == 10_000)
  }

  @Test func shouldKnowThePaceFromTheLastThreeClosedMonthsCountingZeros() throws {
    let steady = try S.overview(S.book(deposits: S.steadyDeposits)).pace
    #expect(steady.state == .known(perMonthMinor: 10_000))
    #expect(steady.months.map(\.month) == [S.date("2026-08-01"), S.date("2026-09-01"), S.date("2026-10-01")])

    let zeros = try S.overview(
      S.book(deposits: [S.deposit("2026-07", 90_000), S.deposit("2026-08", 30_000), S.deposit("2026-09", 0), S.deposit("2026-10", 0)])
    ).pace
    #expect(zeros.state == .known(perMonthMinor: 10_000), "only the last three months count, and a month that saved nothing counts as zero")

    let second = BudgetRecord(id: BudgetStandingsFixture.id(1), name: "Krone", currency: S.usd, limitMinor: 1, period: .monthly, createdOn: S.date("2026-01-01"))
    let together = try S.overview(
      S.book(budgets: [S.home(), second], deposits: S.steadyDeposits + [S.deposit("2026-10", 6_000, budget: second.id)])
    ).pace
    #expect(together.state == .known(perMonthMinor: 12_000), "a month's deposits add up across budgets")
  }

  @Test func shouldCountPaceMonthsOnlyFromTheFirstDepositCapableClose() throws {
    let young = try S.overview(
      S.book(budgets: [S.home(createdOn: "2026-07-15")], deposits: [S.deposit("2026-08", 0), S.deposit("2026-09", 0), S.deposit("2026-10", 9_000)])
    ).pace
    #expect(young.state == .calibrating(monthsLeft: 1), "August and September were Home's calibration months")
    #expect(young.months.map(\.depositedMinor) == [9_000])

    let new = try S.overview(S.book(budgets: [S.home(createdOn: "2026-11-21")])).pace
    #expect(new.state == .calibrating(monthsLeft: 5), "December and January calibrate, then February and March must close")
  }

  @Test func shouldForecastEachGoalAfterTheGoalsBeforeIt() throws {
    let overview = try S.overview(
      S.book(deposits: S.steadyDeposits, goals: [S.goal(1, target: 50_000, rank: "F"), S.goal(2, target: 10_000, rank: "V")]))
    #expect(overview.forecasts.map(\.state) == [.onTrack(eta: S.date("2027-01-01")), .onTrack(eta: S.date("2027-02-01"))])
    #expect(overview.forecasts.map(\.aheadMinor) == [20_000, 30_000])
  }

  @Test func shouldSayWhetherAGoalWithATargetDateIsAheadOnTrackOrBehind() throws {
    func forecast(_ targetDate: String) throws -> GoalForecast {
      try #require(try S.overview(S.book(deposits: S.steadyDeposits, goals: [S.goal(1, target: 55_000, rank: "V", targetDate: targetDate)])).forecasts.first)
    }
    let ahead = try forecast("2027-05-15")
    #expect(ahead.state == .aheadOfTarget(eta: S.date("2027-02-01"), target: S.date("2027-05-15")))
    #expect(ahead.need?.monthsLeft == 6 && ahead.need?.perMonthMinor == 4_167)
    #expect(ahead.need?.daysLeft == S.date("2027-05-15").days(since: S.today) + 1)

    #expect(try forecast("2027-02-10").state == .onTrack(eta: S.date("2027-02-01")))

    let behind = try forecast("2027-01-10")
    #expect(behind.state == .behind(extraPerMonthMinor: 2_500, extraPerDayMinor: 99))
    #expect(behind.need == GoalTargetNeed(target: S.date("2027-01-10"), monthsLeft: 2, daysLeft: 51, perMonthMinor: 12_500, perDayMinor: 491))

    #expect(try forecast("2026-11-30").state == .behind(extraPerMonthMinor: 25_000, extraPerDayMinor: 2_500), "no close lands before a date this month")
    #expect(try forecast("2026-11-01").state == .onTrack(eta: S.date("2027-02-01")), "a passed target date reads as none")
  }

  @Test func shouldSayWhenThePaceIsUnknownOrNothing() throws {
    let goal = [S.goal(1, target: 10_000, rank: "V")]
    #expect(try S.overview(S.book(deposits: [S.deposit("2026-10", 1_000)], goals: goal)).forecasts.first?.state == .calibrating(monthsLeft: 1))
    let nothing = try S.overview(S.book(deposits: [S.deposit("2026-08", 0), S.deposit("2026-09", 0), S.deposit("2026-10", 0)], goals: goal))
    #expect(nothing.forecasts.first?.state == .noPace)
    #expect(nothing.forecasts.first?.eta == nil)
  }

  @Test func shouldLetAReachedGoalBeBoughtOnlyAfterItsCoolingOff() throws {
    let fresh = try S.overview(S.book(deposits: S.steadyDeposits, goals: [S.goal(1, target: 20_000, rank: "V", createdOn: "2026-11-20")]))
    #expect(fresh.forecasts.first?.state == .reached(buyFrom: S.date("2026-11-23")))
    #expect(fresh.forecasts.first?.eta == nil)
  }

  @Test func shouldOfferALeverOnlyInANonEssentialCategoryThatBringsTheGoalAMonthSooner() throws {
    let spending = ["2026-08-10", "2026-09-10", "2026-10-10"].enumerated().flatMap { index, day in
      [S.expense(10 + index, 25_000, on: day, category: "shopping"), S.expense(20 + index, 300_000, on: day, category: "groceries")]
    }
    let goals = [S.goal(1, target: 55_000, rank: "V")]
    let lever = try #require(try S.overview(S.book(expenses: spending, deposits: S.steadyDeposits, goals: goals)).forecasts.first)
    #expect(lever.state == .lever(category: MoneyReadsFixture.category("shopping"), monthsSooner: 1), "groceries would save more but are essential")
    #expect(lever.lever == GoalLever(category: MoneyReadsFixture.category("shopping"), savingPerMonthMinor: 2_500, monthsSooner: 1, eta: S.date("2027-01-01")))

    let owner = [ExpenseCategoryRecord(key: MoneyReadsFixture.category("groceries"), label: "Groceries", essential: false)]
    let overridden = try S.overview(S.book(expenses: spending, deposits: S.steadyDeposits, goals: goals, categories: owner)).forecasts.first
    #expect(overridden?.state == .lever(category: MoneyReadsFixture.category("groceries"), monthsSooner: 2), "the owner's choice wins")

    let small = [S.expense(10, 3_000, on: "2026-10-10", category: "shopping")]
    #expect(try S.overview(S.book(expenses: small, deposits: S.steadyDeposits, goals: goals)).forecasts.first?.state == .onTrack(eta: S.date("2027-02-01")))
  }

  @Test func shouldSayAWithdrawalThisMonthPushedTheGoalBack() throws {
    let goals = [S.goal(1, target: 30_000, rank: "V")]
    let draw = S.expense(1, 50_000, on: "2026-11-10", fromSavingsMinor: 10_000)
    let forecast = try #require(try S.overview(S.book(expenses: [draw], deposits: S.steadyDeposits, goals: goals)).forecasts.first)
    #expect(forecast.state == .pushedBack(byDays: 30, cause: MoneyReadsFixture.id(1)))
    #expect(forecast.delay?.withdrawnMinor == 10_000)
    #expect(forecast.eta == S.date("2026-12-01"))

    let lastMonth = S.expense(1, 50_000, on: "2026-10-10", fromSavingsMinor: 10_000)
    #expect(try S.overview(S.book(expenses: [lastMonth], deposits: S.steadyDeposits, goals: goals)).forecasts.first?.state == .onTrack(eta: S.date("2026-12-01")))

    let purchase = S.expense(1, 50_000, on: "2026-11-10", fromSavingsMinor: 10_000, goal: S.goalID(2))
    let buying = goals + [S.goal(2, target: 10_000, rank: "k")]
    let bought = try #require(try S.overview(S.book(expenses: [purchase], deposits: S.steadyDeposits, goals: buying)).forecasts.first)
    #expect(bought.delay == nil, "a goal's purchase is no withdrawal that pushes goals back")
    #expect(bought.state == .onTrack(eta: S.date("2026-12-01")))
  }

  @Test func shouldProjectThisMonthsDepositApartFromSavings() throws {
    let overview = try S.overview(S.book(expenses: [S.expense(1, 21_000, on: "2026-11-05")], deposits: S.steadyDeposits))
    #expect(overview.liveMonth?.projectedMinor == 25_000, "reference 55 000 (typical 50 000 × 1.1) less 30 000 projected")
    #expect(overview.liveMonth?.budgets == [HomeBudget.id])
    #expect(overview.balance.balanceMinor == 30_000)

    let calibrating = try S.overview(S.book(budgets: [S.home(createdOn: "2026-10-01")], expenses: [S.expense(1, 21_000, on: "2026-11-05")]))
    #expect(calibrating.liveMonth == nil)
  }

  @Test func shouldReadAndObserveSavingsFromTheStore() async throws {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1"))
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(budgetMinor: 100_000), S.home(), S.deposit("2026-10", 10_000), S.goal(1, target: 30_000, rank: "V")])
    var overviews = SavingsReads.observeOverview(in: stores, today: S.today).makeAsyncIterator()
    let first = try #require(try await overviews.next() ?? nil)
    #expect(first.balance.balanceMinor == 10_000)
    #expect(first.allocation.active.map(\.shareMinor) == [10_000])

    try await MoneyReadsFixture.seed(stores.main, [S.deposit("2026-09", 5_000)])
    let second = try #require(try await overviews.next() ?? nil)
    #expect(second.allocation.active.map(\.shareMinor) == [15_000])
    #expect(try await SavingsReads.overview(in: stores, today: S.today)?.balance.depositedMinor == 15_000)
  }

  @Test func shouldReadNothingBeforeTheVaultHasSettings() async throws {
    let stores = try MemoirStores.openInMemory()
    #expect(try await SavingsReads.overview(in: stores, today: S.today) == nil)
  }

  @Test func shouldDefaultBuiltInCategoriesToEssentialAndHonourTheOwner() throws {
    let essentials = CategoryEssentials(records: [
      ExpenseCategoryRecord(key: MoneyReadsFixture.category("food"), label: "Food", essential: true),
      ExpenseCategoryRecord(key: MoneyReadsFixture.category("home"), label: "Home", essential: false),
      ExpenseCategoryRecord(key: MoneyReadsFixture.category("bills"), label: "Bills"),
    ])
    #expect(essentials.essential(MoneyReadsFixture.category("food")) == .byOwner(true))
    #expect(essentials.essential(MoneyReadsFixture.category("home")) == .byOwner(false))
    #expect(essentials.essential(MoneyReadsFixture.category("bills")) == .byDefault(true))
    #expect(essentials.essential(MoneyReadsFixture.category("shopping")) == .byDefault(false))
    #expect(essentials.essential(MoneyReadsFixture.category("travel")) == .byDefault(false), "the owner's own categories are not essential by default")
    #expect(
      MoneyBook.builtInCategories.filter { CategoryEssentials(records: []).isEssential($0) }.map(\.key) == ["groceries", "transport", "bills", "health", "home"])

    let overview = try CategoriesOverview.make(
      MoneyBook(
        settings: nil, expenses: [], rates: [],
        categoryRecords: [
          ExpenseCategoryRecord(key: MoneyReadsFixture.category("groceries"), label: "Groceries", essential: false)
        ]), today: S.today)
    #expect(overview.categories.first { $0.key.key == "groceries" }?.essential == .byOwner(false))
    #expect(overview.categories.first { $0.key.key == "health" }?.essential == .byDefault(true))
  }
}
