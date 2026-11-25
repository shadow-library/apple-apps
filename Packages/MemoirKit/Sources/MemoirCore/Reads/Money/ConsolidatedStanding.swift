import Foundation
import ShadowCore
import ShadowStore

/// The budgets whose period holds the account's day (every monthly budget and a trip under way), added up in the home currency. Spending converts as
/// every home total does (`HomeConverter`: the owner's rate, else the locked or recorded one), each expense without its savings part; limits convert at
/// the newest recorded rate of their currency on or before today, never a later day's. It is approximate whenever anything converts, since limits and
/// spending convert at different rates.
public struct ConsolidatedStanding: Sendable, Hashable {
  public let home: CurrencyCode
  public let budgets: [UUID]
  /// What every budget in the view spent, those without a limit or whose limit did not convert included.
  public let spend: BudgetSpend
  /// The sum of the limits that converted; nil when none did.
  public let limitMinor: Int64?
  /// Limits left out of `limitMinor`: no rate on or before today, or one that cannot convert.
  public let limitsPending: PendingConversions
  public let budgetsWithoutLimit: Int
  /// Each budget whose limit converted, its limit less its own spending, added up; a budget without a counted limit takes nothing from what the others
  /// have left. Nil when no limit converted.
  public let leftMinor: Int64?
  public let isApproximate: Bool

  static func make(_ standings: [BudgetPeriodStanding], book: BudgetBook, converter: BudgetConverter, today: LocalDate) -> ConsolidatedStanding {
    let home = converter.home
    let included = standings.filter { if case .current = $0.phase { true } else { false } }
    let toHome = { (expense: ExpenseRecord) in BudgetAmount(converter.homeConverter.homeAmount(of: expense)) }
    var expenses = [ExpenseRecord]()
    var limit: Int128?
    var left: Int128?
    var awaiting = 0
    var unconvertible = 0
    var currencies = Set<String>()
    var withoutLimit = 0
    for standing in included {
      let own = book.expenses(of: standing.id, in: standing.period)
      expenses += own
      guard let budgetLimit = standing.limitMinor else {
        withoutLimit += 1
        continue
      }
      switch convertLimit(budgetLimit, of: standing.budget.currency, converter: converter, today: today) {
      case .converted(let minor):
        limit = (limit ?? 0) + Int128(minor)
        left = (left ?? 0) + Int128(minor) - Int128(BudgetSpend.tally(own, amount: toHome).spentMinor)
      case .awaitingRate:
        awaiting += 1
        currencies.insert(standing.budget.currency.code)
      case .unconvertible:
        unconvertible += 1
      }
    }
    let converts = included.contains { $0.budget.currency != home } || expenses.contains { $0.currency != home && $0.budgetPortion.amountMinor != 0 }
    return ConsolidatedStanding(
      home: home, budgets: included.map(\.id), spend: BudgetSpend.tally(expenses, amount: toHome), limitMinor: limit.map { Int64(clamping: $0) },
      limitsPending: PendingConversions(awaitingRate: awaiting, unconvertible: unconvertible, currencies: currencies.sorted().compactMap(CurrencyCode.init)),
      budgetsWithoutLimit: withoutLimit, leftMinor: left.map { Int64(clamping: $0) }, isApproximate: converts)
  }

  private static func convertLimit(_ limit: Int64, of currency: CurrencyCode, converter: BudgetConverter, today: LocalDate) -> HomeAmount {
    let rate = currency == converter.home ? nil : converter.latestRate(of: currency, onOrBefore: today)?.rate
    return HomeConverter.convert(MoneyAmount(amountMinor: limit, currency: currency), home: converter.home, rate: rate)
  }
}
