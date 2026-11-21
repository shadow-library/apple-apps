import ShadowStore

public enum HomeAmount: Hashable, Sendable {
  case converted(Int64)
  case awaitingRate
  case unconvertible(FinanceError)

  public var minor: Int64? {
    guard case .converted(let minor) = self else { return nil }
    return minor
  }
}

/// Converts expenses into one home currency through the `mm_fx_rate` of the expense's currency, the home currency and the day its rate is for: the
/// day of its locked rate when that quotes the home currency, otherwise its own date. That record is first writer wins, so every expense of a pair and
/// day converts at one rate on every device, even when a device locked an expense from a record that later lost the merge. The locked rate is the
/// fallback until the record arrives, and it keeps the day the rate is for when the expense's date is edited later.
public struct HomeConverter: Sendable {
  public let home: CurrencyCode

  private let rates: [RateKey: DecimalText]

  public init(home: CurrencyCode, rates: some Sequence<FxRateRecord>) {
    self.home = home
    var table = [RateKey: DecimalText]()
    for record in rates where record.quote == home { table[RateKey(base: record.base, date: record.date)] = record.rate }
    self.rates = table
  }

  public func rate(for expense: ExpenseRecord) -> DecimalText? {
    guard let locked = expense.rate, locked.quote == home else { return rates[RateKey(base: expense.currency, date: expense.occurredOn)] }
    return rates[RateKey(base: expense.currency, date: locked.date)] ?? locked.rate
  }

  public func homeAmount(of expense: ExpenseRecord) -> HomeAmount {
    do throws(FinanceError) {
      let amount = MoneyAmount(amountMinor: expense.amountMinor, currency: expense.currency)
      _ = try ISO4217.exponent(of: expense.currency)
      _ = try ISO4217.exponent(of: home)
      guard expense.currency != home else { return .converted(expense.amountMinor) }
      guard let text = rate(for: expense) else { return .awaitingRate }
      return .converted(try HomeConversion.convert(amount, to: home, at: try ExchangeRate(text)).amountMinor)
    } catch {
      return .unconvertible(error)
    }
  }

  private struct RateKey: Hashable {
    let base: CurrencyCode
    let date: LocalDate
  }
}

extension ExpenseRecord {
  /// Capture at write: a foreign expense takes the `mm_fx_rate` already recorded for its own date; without one it saves unconverted and the rate filler
  /// fills it later. Like the reference, writing never calls the rates service.
  public func capturingRate<Source: RecordSource & ~Copyable>(home: CurrencyCode, from source: borrowing Source) throws(FinanceError) -> ExpenseRecord {
    guard currency != home, rate == nil else { return self }
    let reading: MemoirReading<MemoirEntry<FxRateRecord>>
    do throws(StoreError) {
      reading = try FxRateRecord.read(key: .fxRate(base: currency, quote: home, date: occurredOn), in: source)
    } catch {
      throw FinanceError(error)
    }
    guard let record = reading.entry?.record else { return self }
    var captured = self
    captured.rate = ExpenseRate(rate: record.rate, date: occurredOn, quote: home)
    return captured
  }

  /// Creates the expense with its rate captured against the vault's default currency.
  @discardableResult
  public func createCapturingRate(in transaction: inout WriteTransaction) throws(FinanceError) -> ExpenseRecord {
    var written = self
    if let settings = try FinanceLedger.settings(in: transaction) { written = try capturingRate(home: settings.defaultCurrency, from: transaction) }
    do throws(MemoirRecordError) {
      try written.create(in: &transaction)
    } catch {
      throw FinanceError(error)
    }
    return written
  }
}
