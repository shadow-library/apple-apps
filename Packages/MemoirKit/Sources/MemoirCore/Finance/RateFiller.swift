import ShadowCore
import ShadowStore

public struct CurrencyPair: Hashable, Sendable, CustomStringConvertible {
  public let base: CurrencyCode
  public let quote: CurrencyCode

  public init(base: CurrencyCode, quote: CurrencyCode) {
    self.base = base
    self.quote = quote
  }

  public var description: String { "\(base)/\(quote)" }
}

public enum RatesClientError: ShadowError, Equatable {
  case unavailable(String)
  case refused(status: Int)
  case unreadable(String)

  public var code: String {
    switch self {
    case .unavailable: "memoir_rates.unavailable"
    case .refused: "memoir_rates.refused"
    case .unreadable: "memoir_rates.unreadable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unavailable(let reason): "The rates service could not answer: \(reason)"
    case .refused(let status): "The rates service refused the request with status \(status)."
    case .unreadable(let reason): "The rates service's answer could not be read: \(reason)"
    }
  }
}

/// The only thing that leaves the device is a set of currency pairs and a date. A pair the service has no rate for is left out of the answer; a rate
/// is never made up.
public protocol RatesClient: Sendable {
  func rates(for pairs: Set<CurrencyPair>, on date: LocalDate) async throws(RatesClientError) -> [CurrencyPair: DecimalText]
}

public struct RateFillReport: Hashable, Sendable {
  public var recordedRates = 0
  public var filledExpenses = 0
  public var unavailable: [LocalDate: Set<CurrencyPair>] = [:]
  public var failedDates: [LocalDate] = []
  public var deferredDates: [LocalDate] = []

  public init() {}
}

/// What a fill would ask the rates service for, by date, and whether an expense could lock a rate already recorded without asking.
public struct RateRequests: Hashable, Sendable {
  public static let none = RateRequests(dates: [:], pendingLocks: false)

  public let dates: [LocalDate: Set<CurrencyPair>]
  public let pendingLocks: Bool

  public init(dates: [LocalDate: Set<CurrencyPair>], pendingLocks: Bool) {
    self.dates = dates
    self.pendingLocks = pendingLocks
  }

  public var isEmpty: Bool { dates.isEmpty && !pendingLocks }

  /// Each pair with the date it is asked on.
  public var dated: Set<DatedPair> { Set(dates.flatMap { date, pairs in pairs.map { DatedPair(pair: $0, date: date) } }) }
}

public struct DatedPair: Hashable, Sendable {
  public let pair: CurrencyPair
  public let date: LocalDate

  public init(pair: CurrencyPair, date: LocalDate) {
    self.pair = pair
    self.date = date
  }
}

/// Fills the rates of foreign expenses for their own date, as the reference's reconciliation sweep does: each rate is recorded once per pair and day
/// as an `mm_fx_rate` (first writer wins), and each expense still without a rate locks it. Two devices filling the same pair and day converge on the
/// record written first, and ``HomeConverter`` converts through that record, so an expense locked from the losing record still converts at the winner.
/// Expenses dated after `today` wait for their day; one in a currency outside ``ISO4217`` is never asked about, and neither is the currency of one the
/// owner gave a rate. An expense counted in a budget whose currency is neither home nor its own also asks for that budget's currency against home on
/// its date, which ``BudgetConverter`` inverts, even when the owner gave the expense a rate, since that rate reaches only home.
/// An active subscription in a currency with no recorded rate in the week up to `today` asks for yesterday's, the latest day likely to have a final
/// daily rate, as the reference warms its rate cache; it is not asked when an expense in its currency, or a budget in it, already asks for a date up
/// to `today`.
public struct RateFiller: Sendable {
  public static let defaultMaximumDates = 30
  public static let subscriptionRateDays = 7

  public let client: any RatesClient
  public let maximumDates: Int

  public init(client: any RatesClient, maximumDates: Int = defaultMaximumDates) {
    self.client = client
    self.maximumDates = maximumDates
  }

  /// `asking` narrows the pairs asked to those named; the locks a recorded rate allows are taken either way.
  public func fill(_ store: VaultStore, today: LocalDate, asking: Set<DatedPair>? = nil) async throws(FinanceError) -> RateFillReport {
    var report = RateFillReport()
    let requests: RateRequests
    do throws(StoreError) {
      requests = try await store.read { transaction in try Self.requests(in: transaction, today: today) }
    } catch {
      throw FinanceError(error)
    }
    let asked = requests.dates.reduce(into: [LocalDate: Set<CurrencyPair>]()) { asked, entry in
      let pairs = entry.value.filter { asking?.contains(DatedPair(pair: $0, date: entry.key)) ?? true }
      if !pairs.isEmpty { asked[entry.key] = pairs }
    }
    let dates = asked.keys.sorted(by: >)
    report.deferredDates = Array(dates.dropFirst(max(maximumDates, 0))).sorted()
    var fetched = [FxRateRecord]()
    for date in dates.prefix(max(maximumDates, 0)).sorted() {
      let pairs = asked[date] ?? []
      let answer: [CurrencyPair: DecimalText]
      do throws(RatesClientError) {
        answer = try await client.rates(for: pairs, on: date)
      } catch {
        report.failedDates.append(date)
        continue
      }
      var missing = pairs
      for pair in pairs.sorted(by: { $0.description < $1.description }) {
        guard let text = answer[pair], let rate = try? ExchangeRate.rounded(text) else { continue }
        fetched.append(FxRateRecord(base: pair.base, quote: pair.quote, date: date, rate: rate.text))
        missing.remove(pair)
      }
      if !missing.isEmpty { report.unavailable[date] = missing }
    }
    guard !fetched.isEmpty || requests.pendingLocks else { return report }
    let records = fetched
    let written: (recorded: Int, filled: Int)
    do throws(StoreError) {
      written = try await store.write { transaction in try Self.record(records, today: today, in: &transaction) }
    } catch {
      throw FinanceError(error)
    }
    report.recordedRates = written.recorded
    report.filledExpenses = written.filled
    return report
  }

  /// What ``fill(_:today:)`` would ask for now; empty until the vault has its settings.
  public static func requests<Source: RecordSource & ~Copyable>(in source: borrowing Source, today: LocalDate) throws(FinanceError) -> RateRequests {
    let ledger = try FinanceLedger.load(from: source)
    let subscriptions: MemoirListing<MemoirEntry<SubscriptionRecord>>
    do throws(StoreError) {
      subscriptions = try SubscriptionRecord.listing(in: source)
    } catch {
      throw FinanceError(error)
    }
    let assignments = BudgetAssignments(
      budgets: try Budgets.live(in: source), expenses: ledger.expenses,
      subscriptions: Dictionary(subscriptions.entries.map { ($0.record.id, $0.record) }) { first, _ in first })
    return requests(ledger, subscriptions: subscriptions.entries.filter { !$0.isRemoved }.map(\.record), assignments: assignments, today: today)
  }

  static func requests(_ ledger: FinanceLedger, subscriptions: [SubscriptionRecord], assignments: BudgetAssignments? = nil, today: LocalDate) -> RateRequests {
    guard let budgetConverter = ledger.budgetConverter else { return .none }
    let converter = budgetConverter.homeConverter
    var dates = [LocalDate: Set<CurrencyPair>]()
    var pendingLocks = false
    for expense in candidates(ledger.expenses, converter: converter, today: today) {
      guard converter.referenceRate(for: expense) == nil else {
        if expense.rate == nil { pendingLocks = true }
        continue
      }
      dates[expense.occurredOn, default: []].insert(CurrencyPair(base: expense.currency, quote: converter.home))
    }
    for (date, pair) in budgetRequests(assignments, converter: budgetConverter, today: today) { dates[date, default: []].insert(pair) }
    let asked = Set(dates.values.joined().map(\.base))
    guard let yesterday = today.adding(days: -1), let freshSince = today.adding(days: -subscriptionRateDays) else {
      return RateRequests(dates: dates, pendingLocks: pendingLocks)
    }
    let recorded = Set(ledger.rates.filter { $0.quote == converter.home && $0.date <= today && $0.date > freshSince }.map(\.base))
    for subscription in subscriptions where subscription.active && isForeign(subscription.currency, home: converter.home) {
      guard !asked.contains(subscription.currency), !recorded.contains(subscription.currency) else { continue }
      dates[yesterday, default: []].insert(CurrencyPair(base: subscription.currency, quote: converter.home))
    }
    return RateRequests(dates: dates, pendingLocks: pendingLocks)
  }

  private static func record(_ fetched: [FxRateRecord], today: LocalDate, in transaction: inout WriteTransaction) throws -> (recorded: Int, filled: Int) {
    var recorded = 0
    for record in fetched {
      guard try FxRateRecord.read(key: record.key, in: transaction) == .absent else { continue }
      try record.create(in: &transaction)
      recorded += 1
    }
    let ledger = try FinanceLedger.load(from: transaction)
    guard let converter = ledger.converter else { return (recorded, 0) }
    var filled = 0
    for expense in candidates(ledger.expenses, converter: converter, today: today) where expense.rate == nil {
      guard let rate = converter.referenceRate(for: expense) else { continue }
      try ExpenseRecord.edit(id: expense.id, in: &transaction) { $0.rate = ExpenseRate(rate: rate, date: expense.occurredOn, quote: converter.home) }
      filled += 1
    }
    return (recorded, filled)
  }

  private static func budgetRequests(_ assignments: BudgetAssignments?, converter: BudgetConverter, today: LocalDate) -> [(LocalDate, CurrencyPair)] {
    guard let assignments else { return [] }
    return assignments.expenses.compactMap { expense in
      guard expense.occurredOn <= today, let assignment = assignments.assignments[expense.id], let budget = assignments.budgets.budget(assignment.budget),
        let pair = converter.missingRate(for: expense, in: budget.currency)
      else { return nil }
      return (expense.occurredOn, pair)
    }
  }

  private static func candidates(_ expenses: [ExpenseRecord], converter: HomeConverter, today: LocalDate) -> [ExpenseRecord] {
    expenses.filter { isForeign($0.currency, home: converter.home) && $0.occurredOn <= today && converter.manualRate(of: $0) == nil }
  }

  private static func isForeign(_ currency: CurrencyCode, home: CurrencyCode) -> Bool {
    currency != home && ISO4217.exponents[currency.code] != nil
  }
}
