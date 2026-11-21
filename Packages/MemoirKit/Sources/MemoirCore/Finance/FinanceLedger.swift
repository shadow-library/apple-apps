import ShadowStore

/// What the finance screens read in one transaction: the settings, the live expenses and a converter into the default currency.
public struct FinanceLedger: Sendable {
  public let settings: AccountSettingsRecord?
  public let expenses: [ExpenseRecord]
  public let rates: [FxRateRecord]
  public let unreadable: Int

  public static func load<Source: RecordSource & ~Copyable>(from source: borrowing Source) throws(FinanceError) -> FinanceLedger {
    let expenses: MemoirListing<MemoirEntry<ExpenseRecord>>
    let rates: MemoirListing<MemoirEntry<FxRateRecord>>
    do throws(StoreError) {
      expenses = try ExpenseRecord.listing(in: source)
      rates = try FxRateRecord.listing(in: source)
    } catch {
      throw FinanceError(error)
    }
    return FinanceLedger(
      settings: try settings(in: source), expenses: expenses.entries.filter { !$0.isRemoved }.map(\.record), rates: rates.entries.map(\.record),
      unreadable: expenses.unreadable + rates.unreadable)
  }

  public var converter: HomeConverter? {
    settings.map { HomeConverter(home: $0.defaultCurrency, rates: rates) }
  }

  public func spend(inMonthOf date: LocalDate) throws(FinanceError) -> MonthSpend? {
    guard let converter else { return nil }
    return try MonthSpend(monthOf: date, expenses: expenses, converter: converter)
  }

  public func budgetStanding(today: LocalDate) throws(FinanceError) -> BudgetStanding? {
    guard let settings, let converter else { return nil }
    return try BudgetStanding(settings: settings, expenses: expenses, converter: converter, today: today)
  }

  static func settings<Source: RecordSource & ~Copyable>(in source: borrowing Source) throws(FinanceError) -> AccountSettingsRecord? {
    let reading: MemoirReading<MemoirEntry<AccountSettingsRecord>>
    do throws(StoreError) {
      reading = try AccountSettingsRecord.read(key: .accountSettings, in: source)
    } catch {
      throw FinanceError(error)
    }
    switch reading {
    case .absent: return nil
    case .readable(let entry): return entry.record
    case .unreadable: throw .unreadable(MemoirKey.accountSettings.ref)
    }
  }
}
