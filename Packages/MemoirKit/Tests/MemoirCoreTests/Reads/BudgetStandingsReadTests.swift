import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Budget standings reads", TestTimeLimit.standard)
struct BudgetStandingsReadTests {
  private typealias F = BudgetStandingsFixture

  private static func stores() async throws -> MemoirStores {
    let stores = try MemoirStores.openInMemory(projection: try MemoirReconciler(appVersion: "1"))
    try await MoneyReadsFixture.seed(stores.main, [MoneyReadsFixture.settings(budgetMinor: 100_000)])
    return stores
  }

  private static func command(_ number: Int, _ body: MemoirCommandBody, on date: String) throws -> MemoirCommand {
    try ProjectionSupport.command(
      MemoirStoreFixture.commandID(number), body, at: try ProjectionSupport.stamp(MoneyReadsFixture.date(date), plus: 0), rulesetVersion: Ruleset.v2.version)
  }

  @Test func shouldReadCoverageFromTheProjectionAndEmitAgainAfterAnExpenseIsWritten() async throws {
    let stores = try await Self.stores()
    try await ProjectionSupport.append(
      [
        try Self.command(1, .moneyNoSpend(NoSpendDay(date: MoneyReadsFixture.date("2026-11-02"))), on: "2026-11-02"),
        try Self.command(2, .moneyNoSpend(NoSpendDay(date: MoneyReadsFixture.date("2026-11-03"))), on: "2026-11-03"),
      ], to: stores.main)

    var standings = MoneyReads.observeBudgetStandings(in: stores, today: F.today).makeAsyncIterator()
    let first = try #require(try await standings.next() ?? nil)
    #expect(first.homeBudget?.coverage == LoggingCoverage(coveredDays: 2, daysSoFar: 21))
    #expect(first.homeBudget?.spend.spentMinor == 0)

    try await MoneyReadsFixture.seed(stores.main, [F.expense(1, 1_500, on: "2026-11-04")])
    let second = try #require(try await standings.next() ?? nil)
    #expect(second.homeBudget?.spend.spentMinor == 1_500)
    #expect(second.homeBudget?.leftMinor == 98_500)
  }

  @Test func shouldCutAClosedMonthAtItsCloseCommandsInstant() async throws {
    let stores = try await Self.stores()
    try await MoneyReadsFixture.seed(
      stores.main,
      [
        F.home(createdOn: "2026-09-01"), F.expense(1, 1_000, on: "2026-10-10"), F.expense(2, 2_000, on: "2026-10-30", loggedOn: "2026-11-05"),
        F.expense(3, 4_000, on: "2026-10-31", loggedOn: "2026-11-07"),
      ])
    let close = try Self.command(
      1, .budgetClosePeriod(try BudgetPeriodClose(budgetId: HomeBudget.id, periodStart: MoneyReadsFixture.date("2026-10-01"), outcome: .within, deposited: false)),
      on: "2026-11-06")
    try await ProjectionSupport.append([close], to: stores.main)

    let standings = try #require(try await MoneyReads.budgetStandings(in: stores, today: F.today))
    let october = try #require(standings.homeBudget?.history?.months.last)
    #expect(october.isClosed)
    guard case .logged(let cutoff, _) = october.source else { throw MemoirFixtureError(description: "no deposit record yet") }
    #expect(cutoff == close.instantMillis)
    #expect(october.spentMinor == 3_000, "logged after the grace but before the close counts; after the close, not")

    let overview = try #require(try await MoneyReads.overview(in: stores, today: F.today))
    #expect(overview.budgets == standings, "the overview carries the same standings")

    let deposit = SavingsDeposit(
      amountMinor: 0, currency: F.eur, closedOn: MoneyReadsFixture.date("2026-11-06"), command: close.id, spentMinor: 2_500, limitMinor: 80_000, medianExpenseMinor: 1_250)
    try await MoneyReadsFixture.seed(
      stores.main, [SavingsDepositRecord(budget: HomeBudget.id, periodStart: MoneyReadsFixture.date("2026-10-01"), deposit: deposit)])
    let frozen = try #require(try await MoneyReads.budgetStandings(in: stores, today: F.today)?.homeBudget?.history?.months.last)
    #expect(frozen.source == .closeSnapshot(deposit) && frozen.spentMinor == 2_500 && frozen.limitMinor == 80_000 && frozen.medianExpenseMinor == 1_250)
  }
}
