import Foundation
import ShadowCore
import ShadowStore

/// What budget standings are computed from, read in one transaction of the main store: the live budgets with the expense each counts in, the rates,
/// the days replay found covered, the instant each close replay kept was issued at, the deposit records closes wrote, and the account's zone.
public struct BudgetBook: Sendable, Equatable {
  public let settings: AccountSettingsRecord?
  public let assignments: BudgetAssignments
  public let rates: [FxRateRecord]
  /// Replay's covered days (`MemoirDerived.coveredDays`), the one source of a period's logging coverage.
  public let coveredDays: Set<LocalDate>
  /// The recorded instant of each period's close, by budget and period start.
  public let closeInstants: [MoneyCloseKey: Int64]
  /// The deposit record of each closed period, by budget and period start, which freezes the spending and limit its close judged.
  public let deposits: [MoneyCloseKey: SavingsDeposit]
  public let zone: AccountZone
  /// Into the account's default currency; nil before the vault has settings.
  public let converter: BudgetConverter?

  public init(
    settings: AccountSettingsRecord?, assignments: BudgetAssignments, rates: [FxRateRecord], coveredDays: Set<LocalDate>, closeInstants: [MoneyCloseKey: Int64],
    deposits: [MoneyCloseKey: SavingsDeposit] = [:], zone: AccountZone
  ) {
    self.settings = settings
    self.assignments = assignments
    self.rates = rates
    self.coveredDays = coveredDays
    self.closeInstants = closeInstants
    self.deposits = deposits
    self.zone = zone
    converter = settings.map { BudgetConverter(home: $0.defaultCurrency, rates: rates) }
  }

  /// The converter is built from the settings and rates, so it is left out.
  public static func == (lhs: BudgetBook, rhs: BudgetBook) -> Bool {
    lhs.settings == rhs.settings && lhs.assignments == rhs.assignments && lhs.rates == rhs.rates && lhs.coveredDays == rhs.coveredDays
      && lhs.closeInstants == rhs.closeInstants && lhs.deposits == rhs.deposits && lhs.zone == rhs.zone
  }

  public static func load(from transaction: ReadTransaction) throws(MemoirReadError) -> BudgetBook {
    let ledger: FinanceLedger
    do throws(FinanceError) {
      ledger = try FinanceLedger.load(from: transaction)
    } catch {
      throw .finance(error)
    }
    return try load(from: transaction, settings: ledger.settings, expenses: ledger.expenses, rates: ledger.rates)
  }

  static func load(from transaction: ReadTransaction, money book: MoneyBook) throws(MemoirReadError) -> BudgetBook {
    try load(from: transaction, settings: book.settings, expenses: book.expenses, rates: book.rates)
  }

  private static func load(from transaction: ReadTransaction, settings: AccountSettingsRecord?, expenses: [ExpenseRecord], rates: [FxRateRecord]) throws(MemoirReadError)
    -> BudgetBook
  {
    do throws(StoreError) {
      let budgets = Budgets(try BudgetRecord.listing(in: transaction), settings: settings)
      let subscriptions = try SubscriptionRecord.listing(in: transaction).entries.map(\.record)
      let covered = try MemoirDerived.coveredDays(from: .earliest, through: .latest, in: transaction)
      let deposits = try SavingsDepositRecord.listing(in: transaction).entries.map(\.record)
      var instants = [MoneyCloseKey: Int64]()
      for row in try MemoirDerived.moneyCloses(in: transaction) {
        guard let command = try MemoirCommand.read(id: row.close.command, in: transaction).entry?.record else { continue }
        instants[row.key] = command.instantMillis
      }
      return BudgetBook(
        settings: settings,
        assignments: BudgetAssignments(
          budgets: budgets, expenses: expenses, subscriptions: Dictionary(subscriptions.map { ($0.id, $0) }) { first, _ in first }),
        rates: rates, coveredDays: Set(covered.map(\.date)), closeInstants: instants,
        deposits: Dictionary(deposits.map { (MoneyCloseKey(budget: $0.budget, periodStart: $0.periodStart), $0.deposit) }) { first, _ in first },
        zone: try AccountZone.load(in: transaction))
    } catch {
      throw MemoirReadError(error)
    }
  }

  /// The live budgets, with Home stood in for until `HomeBudget.ensure` writes it: monthly, in the account's default currency, its limit the account's
  /// monthly budget, created `today`, so it has no history yet.
  func liveBudgets(today: LocalDate) -> [LiveBudget] {
    let budgets = assignments.budgets
    guard budgets.home == nil, let settings else { return budgets.live }
    let home = BudgetRecord(id: HomeBudget.id, currency: settings.defaultCurrency, period: .monthly, createdOn: today)
    return [LiveBudget(record: home, settings: settings)] + budgets.live
  }

  /// The expenses a budget counts in `period`, oldest first, so the one an overflow leaves out is the same on every device.
  func expenses(of budget: UUID, in period: BudgetPeriod) -> [ExpenseRecord] {
    assignments.expenses(assignedTo: budget).filter { period.span.contains($0.occurredOn) }.sorted { first, second in
      first.occurredOn != second.occurredOn ? first.occurredOn < second.occurredOn : first.id.uuidString < second.id.uuidString
    }
  }

  /// Which expenses a past period's spending counts: those logged before its close was issued, or, while it is not closed, before the end of its last
  /// grace day in the account's zone. That is the zone in force on the open day (the staged one once it governs), so a zone change after the period
  /// moves the cutoff by at most the difference of the offsets; before any zone is set, UTC. Nil when the date falls outside the calendar.
  func cutoffMillis(of budget: UUID, period: BudgetPeriod) -> Int64? {
    if let instant = closeInstants[MoneyCloseKey(budget: budget, periodStart: period.start)] { return instant }
    guard let day = period.end.adding(days: BudgetThresholds.closeGraceDays + 1), let utc = TimeZone(identifier: "UTC") else { return nil }
    let (approximate, overflow) = Int64(day.daysSinceEpoch).multipliedReportingOverflow(by: 86_400_000)
    guard !overflow else { return nil }
    return try? zone.clock(at: approximate, device: utc).startOfDay(day)
  }
}

/// The read-side thresholds of budgets, from the approved plan; replay's own thresholds are in `MoneyRules`.
public enum BudgetThresholds {
  /// A budget is at risk once spending reaches this share of its limit, in thousandths.
  public static let atRiskThousandths: Int64 = 800
  /// The complete months a typical month is the median of.
  public static let typicalMonths = 3
  /// A budget calibrates until it has this many complete months.
  public static let calibrationMonths = 2
  /// A one-off is at least this many times the typical single expense.
  public static let oneOffMultiple: Int64 = 10
  /// While no typical single expense is known, a one-off is at least this share of the limit, in thousandths.
  public static let oneOffLimitThousandths: Int64 = 100
  public static var closeGraceDays: Int { (Ruleset.current.money ?? .v2).closeGraceDays }
}
