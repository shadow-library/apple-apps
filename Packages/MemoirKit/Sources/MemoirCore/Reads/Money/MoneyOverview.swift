import Foundation
import ShadowStore

/// One range's spending, as memoir-web's `rangeSpend` (`lib/data/finance.provider.ts:423-450`) reads it, in the home currency. Expenses still
/// waiting for a rate are left out of every sum and counted in `spent.pending` (decision 7), where the reference adds them as zero.
public struct RangeSpend: Sendable, Hashable {
  public let range: FinanceRange
  public let period: DateSpan
  public let spent: HomeTotal
  /// The days of the period up to today, which the delta compares with the same stretch of the previous period.
  public let spentSoFarMinor: Int64
  public let comparison: DateSpan?
  public let previousMinor: Int64
  public let delta: Fraction?
  /// `spent` over the days that hold an expense, halves up; zero when none does.
  public let averagePerDayMinor: Int64
  public let daysLogged: Int
  /// Categories with at least one expense, largest first.
  public let categories: [CategorySlice]
  public let currencies: [CurrencyTotal]
}

/// What the Money screen's head shows: the three ranges, every budget's standing, the subscriptions' monthly cost and which one needs the owner next.
public struct MoneyOverview: Sendable, Hashable {
  public let home: CurrencyCode
  public let today: LocalDate
  public let week: RangeSpend
  public let month: RangeSpend
  public let year: RangeSpend
  public let budgets: BudgetStandings
  public let subscriptions: SubscriptionTotals
  public let highlight: SubscriptionHighlight?
  public let expensesThisMonth: Int
  public let unreadable: Int

  public func spend(_ range: FinanceRange) -> RangeSpend {
    switch range {
    case .week: week
    case .month: month
    case .year: year
    }
  }

  /// `nil` until the vault has its settings, which name the home currency.
  public static func make(_ book: MoneyBook, budgets: BudgetBook, today: LocalDate) throws(FinanceError) -> MoneyOverview? {
    guard let settings = book.settings, let converter = book.converter, let standings = try BudgetStandings.make(budgets, today: today) else { return nil }
    let subscriptions = try SubscriptionsOverview.make(book, today: today)
    guard let month = DateSpan.month(of: today) else { throw .dateOutOfRange }
    return MoneyOverview(
      home: settings.defaultCurrency, today: today, week: try rangeSpend(.week, book: book, converter: converter, today: today),
      month: try rangeSpend(.month, book: book, converter: converter, today: today), year: try rangeSpend(.year, book: book, converter: converter, today: today),
      budgets: standings, subscriptions: subscriptions?.totals ?? .empty,
      highlight: subscriptions?.highlight, expensesThisMonth: book.expenses.count { month.contains($0.occurredOn) }, unreadable: book.unreadable)
  }

  static func rangeSpend(_ range: FinanceRange, book: MoneyBook, converter: HomeConverter, today: LocalDate) throws(FinanceError) -> RangeSpend {
    guard let period = range.period(containing: today) else { throw .dateOutOfRange }
    let inRange = book.expenses.filter { period.contains($0.occurredOn) }
    let spent = try HomeTotal(home: converter.home, expenses: inRange, converter: converter)
    let soFar = try HomeTotal(home: converter.home, expenses: inRange.filter { $0.occurredOn <= today }, converter: converter)
    let comparison = range.previousStretch(before: today)
    let previous = try comparison.map { span throws(FinanceError) in
      try HomeTotal(home: converter.home, expenses: book.expenses.filter { span.contains($0.occurredOn) }, converter: converter).totalMinor
    }
    let daysLogged = Set(inRange.map(\.occurredOn)).count
    let average = daysLogged > 0 ? Int64(clamping: Exact.roundHalfUp(Int128(spent.totalMinor), Int128(daysLogged))) : 0
    return RangeSpend(
      range: range, period: period, spent: spent, spentSoFarMinor: soFar.totalMinor, comparison: comparison, previousMinor: previous ?? 0,
      delta: SpendDelta.fraction(current: soFar.totalMinor, previous: previous ?? 0), averagePerDayMinor: average, daysLogged: daysLogged,
      categories: try book.breakdown(inRange, converter: converter).filter { $0.count > 0 }, currencies: try book.currencyTotals(inRange, converter: converter))
  }
}

public enum MoneyReads {
  public static func overview(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> MoneyOverview? {
    try await read(stores, OverviewSource.load) { source throws(FinanceError) in try MoneyOverview.make(source.book, budgets: source.budgets, today: today) }
  }

  public static func observeOverview(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<MoneyOverview?, any Error> {
    observe(stores, OverviewSource.load) { source throws(FinanceError) in try MoneyOverview.make(source.book, budgets: source.budgets, today: today) }
  }

  public static func budgetStandings(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> BudgetStandings? {
    try await read(stores, BudgetBook.load) { book throws(FinanceError) in try BudgetStandings.make(book, today: today) }
  }

  public static func observeBudgetStandings(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<BudgetStandings?, any Error> {
    observe(stores, BudgetBook.load) { book throws(FinanceError) in try BudgetStandings.make(book, today: today) }
  }

  public static func expenses(in stores: MemoirStores, matching query: ExpenseQuery) async throws(MemoirReadError) -> ExpenseListing {
    try await read(stores) { book throws(FinanceError) in try ExpenseListing.make(book, query: query) }
  }

  public static func observeExpenses(in stores: MemoirStores, matching query: ExpenseQuery) -> AsyncThrowingStream<ExpenseListing, any Error> {
    observe(stores) { book throws(FinanceError) in try ExpenseListing.make(book, query: query) }
  }

  public static func subscriptions(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> SubscriptionsOverview? {
    try await read(stores) { book throws(FinanceError) in try SubscriptionsOverview.make(book, today: today) }
  }

  public static func observeSubscriptions(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<SubscriptionsOverview?, any Error> {
    observe(stores) { book throws(FinanceError) in try SubscriptionsOverview.make(book, today: today) }
  }

  public static func categories(in stores: MemoirStores, today: LocalDate) async throws(MemoirReadError) -> CategoriesOverview {
    try await read(stores) { book throws(FinanceError) in try CategoriesOverview.make(book, today: today) }
  }

  public static func observeCategories(in stores: MemoirStores, today: LocalDate) -> AsyncThrowingStream<CategoriesOverview, any Error> {
    observe(stores) { book throws(FinanceError) in try CategoriesOverview.make(book, today: today) }
  }

  public static func history(of expense: UUID, in stores: MemoirStores) async throws(MemoirReadError) -> ExpenseHistory {
    try await readCall { () async throws(StoreError) in try await stores.main.read { transaction in try ExpenseHistory.read(expense, in: transaction) } }
  }

  public static func observeHistory(of expense: UUID, in stores: MemoirStores) -> AsyncThrowingStream<ExpenseHistory, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try ExpenseHistory.read(expense, in: transaction) }) { $0 }
  }

  private static func read<Value: Sendable>(_ stores: MemoirStores, _ make: @escaping @Sendable (MoneyBook) throws(FinanceError) -> Value) async throws(MemoirReadError)
    -> Value
  {
    try await read(stores, MoneyBook.load, make)
  }

  private static func read<Source, Value: Sendable>(
    _ stores: MemoirStores, _ load: @escaping @Sendable (ReadTransaction) throws(MemoirReadError) -> Source, _ make: @escaping @Sendable (Source) throws(FinanceError) -> Value
  ) async throws(MemoirReadError) -> Value {
    try await readCall { () async throws(StoreError) in
      try await stores.main.read { transaction in try build(try load(transaction), make) }
    }
  }

  private static func observe<Value: Sendable & Equatable>(_ stores: MemoirStores, _ make: @escaping @Sendable (MoneyBook) throws(FinanceError) -> Value)
    -> AsyncThrowingStream<Value, any Error>
  {
    observe(stores, MoneyBook.load, make)
  }

  private static func observe<Source: Sendable & Equatable, Value: Sendable & Equatable>(
    _ stores: MemoirStores, _ load: @escaping @Sendable (ReadTransaction) throws(MemoirReadError) -> Source, _ make: @escaping @Sendable (Source) throws(FinanceError) -> Value
  ) -> AsyncThrowingStream<Value, any Error> {
    ReadObservation.observe(ObservedRead(stores.main) { transaction in try load(transaction) }) { source in try build(source, make) }
  }

  private static func build<Source, Value>(_ source: Source, _ make: (Source) throws(FinanceError) -> Value) throws(MemoirReadError) -> Value {
    do throws(FinanceError) {
      return try make(source)
    } catch {
      throw .finance(error)
    }
  }
}

/// The overview's two parts, read in one transaction so its budgets and its totals see the same expenses.
struct OverviewSource: Sendable, Equatable {
  let book: MoneyBook
  let budgets: BudgetBook

  static func load(from transaction: ReadTransaction) throws(MemoirReadError) -> OverviewSource {
    let book = try MoneyBook.load(from: transaction)
    return OverviewSource(book: book, budgets: try BudgetBook.load(from: transaction, money: book))
  }
}
