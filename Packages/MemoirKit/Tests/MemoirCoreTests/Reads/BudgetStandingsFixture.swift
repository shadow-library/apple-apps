import Foundation
import ShadowCore
import ShadowStore

@testable import MemoirCore

enum BudgetStandingsFixture {
  /// A Saturday: 21 days of November gone, today included, and 10 left.
  static let today = MoneyReadsFixture.date("2026-11-21")
  static let eur = MoneyReadsFixture.currency("EUR")
  static let gbp = MoneyReadsFixture.currency("GBP")
  static let usd = MoneyReadsFixture.currency("USD")
  static let jpy = MoneyReadsFixture.currency("JPY")

  static func id(_ number: Int) -> UUID {
    MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-%012x", 0xC000 + number))
  }

  static func home(limitMinor: Int64? = 100_000, currency: CurrencyCode = eur, createdOn: String = "2026-11-01", oneOffFromMinor: Int64? = nil) -> BudgetRecord {
    BudgetRecord(
      id: HomeBudget.id, currency: currency, limitMinor: limitMinor, period: .monthly, oneOffFromMinor: oneOffFromMinor, createdOn: MoneyReadsFixture.date(createdOn))
  }

  static func monthly(_ number: Int, _ currency: CurrencyCode, limitMinor: Int64?, createdOn: String = "2026-11-01") -> BudgetRecord {
    BudgetRecord(id: id(number), name: "Monthly \(number)", currency: currency, limitMinor: limitMinor, period: .monthly, createdOn: MoneyReadsFixture.date(createdOn))
  }

  static func trip(_ number: Int, _ currency: CurrencyCode, limitMinor: Int64, from: String, through: String) -> BudgetRecord {
    BudgetRecord(
      id: id(number), name: "Trip \(number)", currency: currency, limitMinor: limitMinor,
      period: .trip(from: MoneyReadsFixture.date(from), through: MoneyReadsFixture.date(through)), createdOn: MoneyReadsFixture.date("2026-11-01"))
  }

  static func expense(
    _ number: Int, _ amountMinor: Int64, _ currency: CurrencyCode = eur, on date: String, loggedOn: String? = nil, hour: Int = 12, fromSavingsMinor: Int64? = nil,
    budget: UUID? = nil, rate: ExpenseRate? = nil
  ) -> ExpenseRecord {
    let occurred = MoneyReadsFixture.date(date)
    return ExpenseRecord(
      id: MoneyReadsFixture.id(number), amountMinor: amountMinor, currency: currency, occurredOn: occurred, category: MoneyReadsFixture.category("food"), rate: rate,
      budget: budget, fromSavingsMinor: fromSavingsMinor, loggedAtMillis: MoneyReadsFixture.millis(MoneyReadsFixture.date(loggedOn ?? date), hour: hour))
  }

  static func book(
    budgets: [BudgetRecord] = [home()], removed: [BudgetRecord] = [], expenses: [ExpenseRecord] = [], rates: [FxRateRecord] = [], covered: [String] = [],
    closes: [MoneyCloseKey: Int64] = [:], deposits: [MoneyCloseKey: SavingsDeposit] = [:], zone: AccountZone = .unset,
    settings: AccountSettingsRecord = MoneyReadsFixture.settings()
  ) -> BudgetBook {
    let listing = MemoirListing(
      entries: budgets.map { MemoirEntry(record: $0, isRemoved: false) } + removed.map { MemoirEntry(record: $0, isRemoved: true) }, unreadable: 0)
    return BudgetBook(
      settings: settings, assignments: BudgetAssignments(budgets: Budgets(listing, settings: settings), expenses: expenses, subscriptions: [:]), rates: rates,
      coveredDays: Set(covered.map(MoneyReadsFixture.date)), closeInstants: closes, deposits: deposits, zone: zone)
  }

  static func standings(_ book: BudgetBook, today: LocalDate = today) throws -> BudgetStandings {
    guard let standings = try BudgetStandings.make(book, today: today) else { throw MemoirFixtureError(description: "the book has settings") }
    return standings
  }

  static func home(_ book: BudgetBook, today: LocalDate = today) throws -> BudgetPeriodStanding {
    guard let home = try standings(book, today: today).homeBudget else { throw MemoirFixtureError(description: "Home always stands") }
    return home
  }
}
