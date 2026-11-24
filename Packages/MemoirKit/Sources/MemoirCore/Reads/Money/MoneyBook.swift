import Foundation
import ShadowCore
import ShadowStore

/// The money records of the main store, read in one transaction: what every Money read model is computed from.
public struct MoneyBook: Sendable, Equatable {
  /// memoir-web `BUILT_IN_CATEGORIES` (`lib/data/finance.types.ts:64-74`) in its order; the app names them.
  public static let builtInCategories: [CategoryKey] = ["food", "groceries", "transport", "bills", "health", "shopping", "home", "subs", "uncat"].compactMap(
    CategoryKey.init)
  public static let uncategorised = CategoryKey("uncat")

  public let settings: AccountSettingsRecord?
  public let expenses: [ExpenseRecord]
  public let rates: [FxRateRecord]
  public let subscriptions: [SubscriptionRecord]
  public let confirmations: [CycleConfirmation]
  public let categoryRecords: [ExpenseCategoryRecord]
  /// Per expense whose latest amount-moving edit was a refund: the total refunded by the refunds since the amount was last set by anything else.
  public let refundedMinor: [UUID: Int64]
  public let unreadable: Int
  /// The built-in categories in their order, then any other category a record names, by key.
  public let categoryKeys: [CategoryKey]

  public init(
    settings: AccountSettingsRecord?, expenses: [ExpenseRecord], rates: [FxRateRecord], subscriptions: [SubscriptionRecord] = [],
    confirmations: [CycleConfirmation] = [], categoryRecords: [ExpenseCategoryRecord] = [], refundedMinor: [UUID: Int64] = [:],
    unreadable: Int = 0
  ) {
    self.settings = settings
    self.expenses = expenses
    self.rates = rates
    self.subscriptions = subscriptions
    self.confirmations = confirmations
    self.categoryRecords = categoryRecords
    self.refundedMinor = refundedMinor
    self.unreadable = unreadable
    categoryKeys = Self.builtInCategories + Set(categoryRecords.map(\.categoryKey)).subtracting(Self.builtInCategories).sorted { $0.key < $1.key }
  }

  public static func load(from transaction: ReadTransaction) throws(MemoirReadError) -> MoneyBook {
    let ledger: FinanceLedger
    do throws(FinanceError) {
      ledger = try FinanceLedger.load(from: transaction)
    } catch {
      throw .finance(error)
    }
    do throws(StoreError) {
      let subscriptions = try ReadSources.listing(SubscriptionRecord.self, in: transaction)
      let categories = try ExpenseCategoryRecord.listing(in: transaction)
      let commands = try ReadSources.commands(in: transaction)
      let confirmations = commands.commands.compactMap { _, body -> CycleConfirmation? in
        guard case .subscriptionConfirmCycle(let confirmation) = body else { return nil }
        return confirmation
      }
      let changes = try ExpenseChangeRecord.listing(in: transaction)
      return MoneyBook(
        settings: ledger.settings, expenses: ledger.expenses, rates: ledger.rates, subscriptions: subscriptions.records, confirmations: confirmations,
        categoryRecords: categories.entries.map(\.record),
        refundedMinor: ExpenseRefundState.refunded(changes.entries),
        unreadable: ledger.unreadable + subscriptions.unreadable + categories.unreadable + commands.unreadable + changes.unreadable)
    } catch {
      throw MemoirReadError(error)
    }
  }

  public var home: CurrencyCode? { settings?.defaultCurrency }

  var converter: HomeConverter? { settings.map { HomeConverter(home: $0.defaultCurrency, rates: rates) } }

  /// memoir-web `categoryById` (`finance.rules.ts:162`): an expense filed under a category nobody knows counts as uncategorised.
  func category(of expense: ExpenseRecord) -> CategoryKey {
    guard let uncategorised = Self.uncategorised, !categoryKeys.contains(expense.category) else { return expense.category }
    return uncategorised
  }

  /// The newest recorded rate into the home currency for each foreign currency, dated on or before `today`.
  func latestRates(home: CurrencyCode, today: LocalDate) -> [CurrencyCode: DecimalText] {
    var newest = [CurrencyCode: FxRateRecord]()
    for rate in rates where rate.quote == home && rate.date <= today {
      if let current = newest[rate.base], current.date >= rate.date { continue }
      newest[rate.base] = rate
    }
    return newest.mapValues(\.rate)
  }
}

extension HomeConverter {
  /// An amount converted at a given rate text; `.awaitingRate` without one.
  static func convert(_ amount: MoneyAmount, home: CurrencyCode, rate: DecimalText?) -> HomeAmount {
    do throws(FinanceError) {
      _ = try ISO4217.exponent(of: amount.currency)
      _ = try ISO4217.exponent(of: home)
      guard amount.currency != home else { return .converted(amount.amountMinor) }
      guard let rate else { return .awaitingRate }
      return .converted(try HomeConversion.convert(amount, to: home, at: try ExchangeRate(rate)).amountMinor)
    } catch {
      return .unconvertible(error)
    }
  }
}

/// Amounts that could not join a home-currency total: still waiting for a rate, or in a currency or at a rate that cannot convert. Decision 7: they are
/// left out of the total and counted here instead of adding nothing silently.
public struct PendingConversions: Sendable, Hashable {
  public static let none = PendingConversions(awaitingRate: 0, unconvertible: 0, currencies: [])

  public let awaitingRate: Int
  public let unconvertible: Int
  /// The currencies of the amounts waiting for a rate, by code.
  public let currencies: [CurrencyCode]

  public var count: Int { awaitingRate + unconvertible }
}

/// A sum in the home currency over the amounts that converted, with the rest counted apart.
public struct HomeTotal: Sendable, Hashable {
  public let home: CurrencyCode
  public let totalMinor: Int64
  public let pending: PendingConversions

  init(home: CurrencyCode, amounts: some Sequence<(currency: CurrencyCode, amount: HomeAmount)>) throws(FinanceError) {
    var total = MoneyAmount(amountMinor: 0, currency: home)
    var awaiting = 0
    var unconvertible = 0
    var currencies = Set<String>()
    for (currency, amount) in amounts {
      switch amount {
      case .converted(let minor): total = try total.adding(MoneyAmount(amountMinor: minor, currency: home))
      case .awaitingRate:
        awaiting += 1
        currencies.insert(currency.code)
      case .unconvertible: unconvertible += 1
      }
    }
    self.home = home
    totalMinor = total.amountMinor
    pending = PendingConversions(awaitingRate: awaiting, unconvertible: unconvertible, currencies: currencies.sorted().compactMap(CurrencyCode.init))
  }

  init(home: CurrencyCode, expenses: some Sequence<ExpenseRecord>, converter: HomeConverter) throws(FinanceError) {
    try self.init(home: home, amounts: expenses.map { ($0.currency, converter.homeAmount(of: $0)) })
  }
}

/// One category's share of a stretch's spending. `count` includes expenses still waiting for a rate, which `totalMinor` leaves out.
public struct CategorySlice: Sendable, Hashable {
  public let category: CategoryKey
  public let count: Int
  public let totalMinor: Int64
  public let pending: PendingConversions
  /// memoir-web `categoryBreakdown` (`finance.rules.ts:166-181`): the total against the largest category's, as a whole percentage, halves up.
  public let percentOfLargest: Int
}

/// Spending in one currency, in that currency's own minor units, with what of it converted home.
public struct CurrencyTotal: Sendable, Hashable {
  public let currency: CurrencyCode
  public let count: Int
  public let totalMinor: Int64
  public let home: HomeTotal
}

extension MoneyBook {
  /// memoir-web `categoryBreakdown`: every category in order with its count and home total, sorted by total, largest first; equal totals keep the
  /// category order.
  func breakdown(_ expenses: [ExpenseRecord], converter: HomeConverter) throws(FinanceError) -> [CategorySlice] {
    let grouped = Dictionary(grouping: expenses, by: category(of:))
    var totals = [(key: CategoryKey, count: Int, total: HomeTotal)]()
    for key in categoryKeys {
      let members = grouped[key] ?? []
      totals.append((key, members.count, try HomeTotal(home: converter.home, expenses: members, converter: converter)))
    }
    let ordered = totals.enumerated().sorted { first, second in
      first.element.total.totalMinor != second.element.total.totalMinor
        ? first.element.total.totalMinor > second.element.total.totalMinor : first.offset < second.offset
    }.map(\.element)
    let largest = ordered.first?.total.totalMinor ?? 0
    return ordered.map { entry in
      let percent = largest > 0 ? Int(clamping: Exact.roundHalfUp(Int128(entry.total.totalMinor) * 100, Int128(largest))) : 0
      return CategorySlice(category: entry.key, count: entry.count, totalMinor: entry.total.totalMinor, pending: entry.total.pending, percentOfLargest: percent)
    }
  }

  /// Per-currency totals, by currency code, each with what of it converted home.
  func currencyTotals(_ expenses: [ExpenseRecord], converter: HomeConverter) throws(FinanceError) -> [CurrencyTotal] {
    try Dictionary(grouping: expenses, by: \.currency).sorted { $0.key.code < $1.key.code }.map { currency, members throws(FinanceError) in
      let own = try MoneyAmount.sum(members.map { MoneyAmount(amountMinor: $0.amountMinor, currency: currency) }, in: currency)
      return CurrencyTotal(
        currency: currency, count: members.count, totalMinor: own.amountMinor, home: try HomeTotal(home: converter.home, expenses: members, converter: converter))
    }
  }
}
