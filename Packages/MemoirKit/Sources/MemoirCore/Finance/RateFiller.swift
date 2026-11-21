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

  public var code: String {
    switch self {
    case .unavailable: "memoir_rates.unavailable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .unavailable(let reason): "The rates service could not answer: \(reason)"
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

/// Fills the rates of foreign expenses for their own date, as the reference's reconciliation sweep does: each rate is recorded once per pair and day
/// as an `mm_fx_rate` (first writer wins), and each expense still without a rate locks it. Two devices filling the same pair and day converge on the
/// record written first, and ``HomeConverter`` converts through that record, so an expense locked from the losing record still converts at the winner.
/// Expenses dated after `today` wait for their day; one in a currency outside ``ISO4217`` is never asked about.
public struct RateFiller: Sendable {
  public static let defaultMaximumDates = 30

  public let client: any RatesClient
  public let maximumDates: Int

  public init(client: any RatesClient, maximumDates: Int = defaultMaximumDates) {
    self.client = client
    self.maximumDates = maximumDates
  }

  public func fill(_ store: VaultStore, today: LocalDate) async throws(FinanceError) -> RateFillReport {
    var report = RateFillReport()
    let requests: [LocalDate: Set<CurrencyPair>]
    let pendingLocks: Bool
    do throws(StoreError) {
      (requests, pendingLocks) = try await store.read { transaction in try Self.plan(FinanceLedger.load(from: transaction), today: today) }
    } catch {
      throw FinanceError(error)
    }
    let dates = requests.keys.sorted(by: >)
    report.deferredDates = Array(dates.dropFirst(max(maximumDates, 0))).sorted()
    var fetched = [FxRateRecord]()
    for date in dates.prefix(max(maximumDates, 0)).sorted() {
      let pairs = requests[date] ?? []
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
    guard !fetched.isEmpty || pendingLocks else { return report }
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

  private static func plan(_ ledger: FinanceLedger, today: LocalDate) -> (requests: [LocalDate: Set<CurrencyPair>], pendingLocks: Bool) {
    guard let converter = ledger.converter else { return ([:], false) }
    var requests = [LocalDate: Set<CurrencyPair>]()
    var pendingLocks = false
    for expense in candidates(ledger.expenses, home: converter.home, today: today) {
      guard converter.rate(for: expense) == nil else {
        if expense.rate == nil { pendingLocks = true }
        continue
      }
      requests[expense.occurredOn, default: []].insert(CurrencyPair(base: expense.currency, quote: converter.home))
    }
    return (requests, pendingLocks)
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
    for expense in candidates(ledger.expenses, home: converter.home, today: today) where expense.rate == nil {
      guard let rate = converter.rate(for: expense) else { continue }
      try ExpenseRecord.edit(id: expense.id, in: &transaction) { $0.rate = ExpenseRate(rate: rate, date: expense.occurredOn, quote: converter.home) }
      filled += 1
    }
    return (recorded, filled)
  }

  private static func candidates(_ expenses: [ExpenseRecord], home: CurrencyCode, today: LocalDate) -> [ExpenseRecord] {
    expenses.filter { $0.currency != home && $0.occurredOn <= today && ISO4217.exponents[$0.currency.code] != nil }
  }
}
