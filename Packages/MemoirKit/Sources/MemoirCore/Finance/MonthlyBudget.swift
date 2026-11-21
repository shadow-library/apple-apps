/// Spending in one calendar month, in the home currency. An expense still waiting for its rate, or one that cannot be converted, adds nothing and is
/// counted instead; the reference adds it as zero without saying so.
public struct MonthSpend: Hashable, Sendable {
  public let home: CurrencyCode
  public let first: LocalDate
  public let last: LocalDate
  public let spentMinor: Int64
  public let awaitingRate: Int
  public let unconvertible: Int

  public init(monthOf date: LocalDate, expenses: some Sequence<ExpenseRecord>, converter: HomeConverter) throws(FinanceError) {
    guard let first = LocalDate(year: date.year, month: date.month, day: 1),
      let last = LocalDate(year: date.year, month: date.month, day: LocalDate.daysInMonth(year: date.year, month: date.month))
    else { throw .dateOutOfRange }
    var spent = MoneyAmount(amountMinor: 0, currency: converter.home)
    var awaiting = 0
    var unconvertible = 0
    for expense in expenses where (first...last).contains(expense.occurredOn) {
      switch converter.homeAmount(of: expense) {
      case .converted(let minor): spent = try spent.adding(MoneyAmount(amountMinor: minor, currency: converter.home))
      case .awaitingRate: awaiting += 1
      case .unconvertible: unconvertible += 1
      }
    }
    home = converter.home
    self.first = first
    self.last = last
    spentMinor = spent.amountMinor
    awaitingRate = awaiting
    self.unconvertible = unconvertible
  }
}

/// memoir-web `budgetStanding`: this month's spending against the monthly budget, with the days left counting today.
public struct BudgetStanding: Hashable, Sendable {
  public let budget: MoneyAmount
  public let spend: MonthSpend
  public let leftMinor: Int64
  public let daysLeft: Int

  /// `nil` when no budget is set, or when the budget is not in the default currency (a currency change merged with a budget set elsewhere).
  public init?(settings: AccountSettingsRecord, expenses: some Sequence<ExpenseRecord>, converter: HomeConverter, today: LocalDate) throws(FinanceError) {
    guard let budget = settings.effectiveMonthlyBudget else { return nil }
    guard converter.home == budget.currency else { throw .currencyMismatch(converter.home, budget.currency) }
    let spend = try MonthSpend(monthOf: today, expenses: expenses, converter: converter)
    self.budget = budget
    self.spend = spend
    leftMinor = try budget.subtracting(MoneyAmount(amountMinor: spend.spentMinor, currency: budget.currency)).amountMinor
    daysLeft = spend.last.days(since: today) + 1
  }
}

extension AccountSettingsRecord {
  public var effectiveMonthlyBudget: MoneyAmount? {
    guard let budget = monthlyBudget, budget.currency == defaultCurrency, budget.amountMinor >= 0 else { return nil }
    return budget
  }

  /// apps/memoir-server/src/modules/account/account.service.ts:165-173: the default currency is always enabled, and changing it clears the budget, which
  /// was kept in the old currency's minor units.
  public mutating func changeDefaultCurrency(to currency: CurrencyCode) throws(FinanceError) {
    _ = try ISO4217.exponent(of: currency)
    var enabled = [currency]
    for code in enabledCurrencies where !enabled.contains(code) { enabled.append(code) }
    enabledCurrencies = enabled
    guard currency != defaultCurrency else { return }
    defaultCurrency = currency
    monthlyBudget = nil
  }

  /// The budget is in the default currency's minor units, zero or more; `nil` clears it.
  public mutating func setMonthlyBudget(amountMinor: Int64?) throws(FinanceError) {
    guard let amountMinor else {
      monthlyBudget = nil
      return
    }
    guard amountMinor >= 0 else { throw .negativeBudget(amountMinor) }
    monthlyBudget = MoneyAmount(amountMinor: amountMinor, currency: defaultCurrency)
  }
}
