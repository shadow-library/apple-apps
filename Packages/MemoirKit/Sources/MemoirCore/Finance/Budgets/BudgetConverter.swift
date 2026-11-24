public enum BudgetAmount: Hashable, Sendable {
  case converted(Int64)
  case awaitingRate
  case unconvertible(FinanceError)

  public var minor: Int64? {
    guard case .converted(let minor) = self else { return nil }
    return minor
  }

  init(_ home: HomeAmount) {
    switch home {
    case .converted(let minor): self = .converted(minor)
    case .awaitingRate: self = .awaitingRate
    case .unconvertible(let error): self = .unconvertible(error)
    }
  }
}

/// The amount of an expense in the currency of the budget it counts in. An expense in the budget's currency counts exactly as written. Any other goes
/// through the home currency, with two roundings, each half up into the minor units of the currency it lands in:
/// 1. into home exactly as ``HomeConverter`` converts it (the owner's rate; else, once locked, the recorded rate of the locked day or the locked rate
///    itself; else the recorded rate of its own date), so the home amount is the one every home total shows;
/// 2. that home amount into the budget's currency through the `mm_fx_rate` of the budget's currency against home on the expense's own date, inverted.
/// A budget in the home currency takes step 1 alone. Neither step leaves the expense's date for a nearer rate: a missing one leaves it awaiting.
public struct BudgetConverter: Sendable {
  public let homeConverter: HomeConverter

  private let rates: [RateKey: DecimalText]

  public init(home: CurrencyCode, rates: some Sequence<FxRateRecord>) {
    let records = Array(rates)
    homeConverter = HomeConverter(home: home, rates: records)
    var table = [RateKey: DecimalText]()
    for record in records where record.quote == home { table[RateKey(base: record.base, date: record.date)] = record.rate }
    self.rates = table
  }

  public var home: CurrencyCode { homeConverter.home }

  /// The recorded price of one unit of `currency` in home on `date`.
  public func recordedRate(of currency: CurrencyCode, on date: LocalDate) -> DecimalText? {
    rates[RateKey(base: currency, date: date)]
  }

  public func amount(of expense: ExpenseRecord, in budget: LiveBudget) -> BudgetAmount {
    amount(of: expense, in: budget.currency)
  }

  public func amount(of expense: ExpenseRecord, in currency: CurrencyCode) -> BudgetAmount {
    do throws(FinanceError) {
      _ = try ISO4217.exponent(of: expense.currency)
      _ = try ISO4217.exponent(of: currency)
      guard expense.currency != currency else { return .converted(expense.amountMinor) }
      let inHome = homeConverter.homeAmount(of: expense)
      guard currency != home, let homeMinor = inHome.minor else { return BudgetAmount(inHome) }
      guard let text = recordedRate(of: currency, on: expense.occurredOn) else { return .awaitingRate }
      let rate = try ExchangeRate(text)
      return .converted(try BudgetConversion.convert(MoneyAmount(amountMinor: homeMinor, currency: home), to: currency, inverting: rate).amountMinor)
    } catch {
      return .unconvertible(error)
    }
  }

  /// The budget-currency rate an expense counted in `currency` waits for, dated on the expense's own day; nil when it needs none, has it, or can
  /// never convert.
  func missingRate(for expense: ExpenseRecord, in currency: CurrencyCode) -> CurrencyPair? {
    guard currency != home, currency != expense.currency else { return nil }
    guard ISO4217.exponents[currency.code] != nil, ISO4217.exponents[expense.currency.code] != nil, ISO4217.exponents[home.code] != nil else { return nil }
    guard recordedRate(of: currency, on: expense.occurredOn) == nil else { return nil }
    return CurrencyPair(base: currency, quote: home)
  }

  private struct RateKey: Hashable {
    let base: CurrencyCode
    let date: LocalDate
  }
}

/// Converts a home amount into another currency through that currency's rate against home (`rate` home units buy one unit of `currency`), inverting
/// it exactly: `roundHalfUp(homeMinor × 10^(scale + eTarget − eHome) / significand)`, halves toward positive infinity as ``HomeConversion`` rounds.
/// The power of ten goes on whichever side keeps it whole, so nothing is truncated before the one rounding.
public enum BudgetConversion {
  public static func convert(_ amount: MoneyAmount, to currency: CurrencyCode, inverting rate: ExchangeRate) throws(FinanceError) -> MoneyAmount {
    let homeExponent = try ISO4217.exponent(of: amount.currency)
    let targetExponent = try ISO4217.exponent(of: currency)
    guard amount.currency != currency else { return amount }
    let shift = rate.scale + targetExponent - homeExponent
    let numerator = Int128(amount.amountMinor)
    var denominator = Int128(rate.significand)
    let scaled: Int128
    if shift >= 0 {
      let (product, overflow) = numerator.multipliedReportingOverflow(by: power(of: shift))
      guard !overflow else { throw .overflow }
      scaled = product
    } else {
      denominator *= power(of: -shift)
      scaled = numerator
    }
    guard let minor = Int64(exactly: HomeConversion.roundHalfUp(scaled, denominator)) else { throw .overflow }
    return MoneyAmount(amountMinor: minor, currency: currency)
  }

  private static func power(of exponent: Int) -> Int128 {
    (0..<exponent).reduce(Int128(1)) { value, _ in value * 10 }
  }
}

extension FinanceLedger {
  public var budgetConverter: BudgetConverter? {
    settings.map { BudgetConverter(home: $0.defaultCurrency, rates: rates) }
  }
}
