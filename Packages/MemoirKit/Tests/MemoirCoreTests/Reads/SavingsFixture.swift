import Foundation
import ShadowCore
import ShadowStore

@testable import MemoirCore

enum SavingsFixture {
  private typealias F = BudgetStandingsFixture

  /// A Saturday in November 2026; Home was created in January, so its months from March on can deposit.
  static let today = F.today
  static let eur = F.eur
  static let usd = F.usd

  static func goalID(_ number: Int) -> UUID {
    MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-%012x", 0xD000 + number))
  }

  static func date(_ text: String) -> LocalDate {
    MoneyReadsFixture.date(text)
  }

  static func home(limitMinor: Int64? = 100_000, currency: CurrencyCode = eur, createdOn: String = "2026-01-01") -> BudgetRecord {
    F.home(limitMinor: limitMinor, currency: currency, createdOn: createdOn)
  }

  static func deposit(
    _ month: String, _ amountMinor: Int64, budget: UUID = HomeBudget.id, currency: CurrencyCode = eur, spentMinor: Int64 = 50_000, limitMinor: Int64? = 100_000
  ) -> SavingsDepositRecord {
    let start = date(month + "-01")
    return SavingsDepositRecord(
      budget: budget, periodStart: start,
      deposit: SavingsDeposit(
        amountMinor: amountMinor, currency: currency, closedOn: start.adding(months: 1) ?? start, command: MemoirStoreFixture.commandID(start.monthIndex),
        spentMinor: spentMinor, limitMinor: limitMinor, medianExpenseMinor: 2_000))
  }

  static func goal(
    _ number: Int, target: Int64, rank: String, createdOn: String = "2026-10-01", state: SavingsGoalState = .active, targetDate: String? = nil,
    currency: CurrencyCode = eur
  ) -> SavingsGoalRecord {
    guard let rank = SavingsGoalRank(rank) else { preconditionFailure("\(rank) is a rank") }
    return SavingsGoalRecord(
      id: goalID(number), name: "Goal \(number)", symbol: "star", targetMinor: target, currency: currency, targetDate: targetDate.map(date), rank: rank,
      createdOn: date(createdOn), state: .known(state))
  }

  static func expense(
    _ number: Int, _ amountMinor: Int64, _ currency: CurrencyCode = eur, on day: String, category: String = "food", fromSavingsMinor: Int64? = nil, goal: UUID? = nil
  ) -> ExpenseRecord {
    ExpenseRecord(
      id: MoneyReadsFixture.id(number), amountMinor: amountMinor, currency: currency, occurredOn: date(day), category: MoneyReadsFixture.category(category),
      fromSavingsMinor: fromSavingsMinor, goal: goal, loggedAtMillis: MoneyReadsFixture.millis(date(day)))
  }

  static func book(
    budgets: [BudgetRecord] = [home()], expenses: [ExpenseRecord] = [], rates: [FxRateRecord] = [], deposits: [SavingsDepositRecord] = [],
    goals: [SavingsGoalRecord] = [], categories: [ExpenseCategoryRecord] = [], settings: AccountSettingsRecord = MoneyReadsFixture.settings()
  ) -> SavingsBook {
    let budgetBook = F.book(
      budgets: budgets, expenses: expenses, rates: rates,
      deposits: Dictionary(deposits.map { (MoneyCloseKey(budget: $0.budget, periodStart: $0.periodStart), $0.deposit) }) { first, _ in first }, settings: settings)
    return SavingsBook(budgets: budgetBook, budgetRecords: budgets, goals: goals, essentials: CategoryEssentials(records: categories))
  }

  static func overview(_ book: SavingsBook, today: LocalDate = today) throws -> SavingsOverview {
    guard let overview = try SavingsOverview.make(book, today: today) else { throw MemoirFixtureError(description: "the book has settings") }
    return overview
  }

  /// Three closed months, August to October, depositing 10 000 each, the pace of every forecast test unless it says otherwise.
  static let steadyDeposits = [deposit("2026-08", 10_000), deposit("2026-09", 10_000), deposit("2026-10", 10_000)]
}
