import Foundation
import ShadowCore
import ShadowStore

/// What budget standings are computed from, read in one transaction of the main store: the live budgets with the expense each counts in, the rates,
/// the days replay found covered, the periods replay closed and the instant each close was issued at, the deposit records closes wrote, the account's
/// zone, and why replay halted, if it did.
public struct BudgetBook: Sendable, Equatable {
  public let settings: AccountSettingsRecord?
  public let assignments: BudgetAssignments
  public let rates: [FxRateRecord]
  /// Replay's covered days (`MemoirDerived.coveredDays`), the one source of a period's logging coverage.
  public let coveredDays: Set<LocalDate>
  /// The recorded instant of each period's close, by budget and period start.
  public let closeInstants: [MoneyCloseKey: Int64]
  /// Every period replay holds a close for, with those whose command this build can no longer read (and so has no instant): such a period stays closed,
  /// and its history counts the expenses logged before its earliest close moment.
  public let closedPeriods: Set<MoneyCloseKey>
  /// The deposit record of each closed period, by budget and period start, which freezes the spending and limit its close judged.
  public let deposits: [MoneyCloseKey: SavingsDeposit]
  public let zone: AccountZone
  /// Set while replay stops at a command this build cannot read: what replay holds may be missing later closes and rewards, so nothing closes.
  public let replayHalt: ReplayHalt?
  /// Into the account's default currency; nil before the vault has settings.
  public let converter: BudgetConverter?

  public init(
    settings: AccountSettingsRecord?, assignments: BudgetAssignments, rates: [FxRateRecord], coveredDays: Set<LocalDate>, closeInstants: [MoneyCloseKey: Int64],
    closedPeriods: Set<MoneyCloseKey>? = nil, deposits: [MoneyCloseKey: SavingsDeposit] = [:], zone: AccountZone, replayHalt: ReplayHalt? = nil
  ) {
    self.settings = settings
    self.assignments = assignments
    self.rates = rates
    self.coveredDays = coveredDays
    self.closeInstants = closeInstants
    self.closedPeriods = closedPeriods ?? Set(closeInstants.keys)
    self.deposits = deposits
    self.zone = zone
    self.replayHalt = replayHalt
    converter = settings.map { BudgetConverter(home: $0.defaultCurrency, rates: rates) }
  }

  /// The converter is built from the settings and rates, so it is left out.
  public static func == (lhs: BudgetBook, rhs: BudgetBook) -> Bool {
    lhs.settings == rhs.settings && lhs.assignments == rhs.assignments && lhs.rates == rhs.rates && lhs.coveredDays == rhs.coveredDays
      && lhs.closeInstants == rhs.closeInstants && lhs.closedPeriods == rhs.closedPeriods && lhs.deposits == rhs.deposits && lhs.zone == rhs.zone
      && lhs.replayHalt == rhs.replayHalt
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
      let closes = try MemoirDerived.moneyCloses(in: transaction)
      for row in closes {
        guard let command = try MemoirCommand.read(id: row.close.command, in: transaction).entry?.record else { continue }
        instants[row.key] = command.instantMillis
      }
      return BudgetBook(
        settings: settings,
        assignments: BudgetAssignments(
          budgets: budgets, expenses: expenses, subscriptions: Dictionary(subscriptions.map { ($0.id, $0) }) { first, _ in first }),
        rates: rates, coveredDays: Set(covered.map(\.date)), closeInstants: instants, closedPeriods: Set(closes.map(\.key)),
        deposits: Dictionary(deposits.map { (MoneyCloseKey(budget: $0.budget, periodStart: $0.periodStart), $0.deposit) }) { first, _ in first },
        zone: try AccountZone.load(in: transaction), replayHalt: try MemoirDerived.hero(in: transaction)?.halt)
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

  /// Which expenses a past period's spending counts: those logged before its close was issued, or, without that instant (not closed, or its close
  /// command unreadable), before its earliest close moment (`earliestCloseMillis`). Nil when the date falls outside the calendar.
  func cutoffMillis(of budget: UUID, period: BudgetPeriod) -> Int64? {
    if let instant = closeInstants[MoneyCloseKey(budget: budget, periodStart: period.start)] { return instant }
    return earliestCloseMillis(of: period)
  }

  /// The first moment a period can close: the start of the day after its last grace day in the account's zone. That is the zone in force on the open day
  /// (the staged one once it governs), so a zone change after the period moves it by at most the difference of the offsets; before any zone is set,
  /// UTC. Nil when the date falls outside the calendar.
  func earliestCloseMillis(of period: BudgetPeriod) -> Int64? {
    earliestCloseDay(of: period).flatMap(startMillis(of:))
  }

  /// The day after a period's last grace day, which its earliest close moment starts.
  func earliestCloseDay(of period: BudgetPeriod) -> LocalDate? {
    period.end.adding(days: BudgetThresholds.closeGraceDays + 1)
  }

  /// The start of `day` in the account's zone, as `earliestCloseMillis` reads it.
  func startMillis(of day: LocalDate) -> Int64? {
    guard let utc = TimeZone(identifier: "UTC") else { return nil }
    let (approximate, overflow) = Int64(day.daysSinceEpoch).multipliedReportingOverflow(by: 86_400_000)
    guard !overflow else { return nil }
    return try? zone.clock(at: approximate, device: utc).startOfDay(day)
  }

  /// A period's spending as the expenses logged before its cutoff count it, and the median of their positive whole amounts in the budget's currency:
  /// what a month's history reads until its close freezes it, and what the close freezes.
  func logged(_ budget: LiveBudget, in period: BudgetPeriod, converter: BudgetConverter) -> LoggedPeriod {
    let cutoff = cutoffMillis(of: budget.id, period: period)
    let expenses = expenses(of: budget.id, in: period).filter { expense in cutoff.map { expense.loggedAtMillis < $0 } ?? true }
    return LoggedPeriod(
      cutoffMillis: cutoff, spend: BudgetSpend.tally(expenses) { converter.amount(of: $0, in: budget.currency) },
      medianExpenseMinor: BudgetHistory.median(expenses.compactMap { expense in converter.amount(of: expense, in: budget.currency).minor.flatMap { $0 > 0 ? $0 : nil } }))
  }
}

struct LoggedPeriod: Sendable, Hashable {
  let cutoffMillis: Int64?
  let spend: BudgetSpend
  let medianExpenseMinor: Int64?
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
  /// A close over its limit by at most this share of it, in thousandths, is `over_10`.
  public static let overSlightThousandths: Int64 = 100
  /// A close over its limit by at most this share of it, in thousandths, is `over_25`; by more, `over_more`.
  public static let overModerateThousandths: Int64 = 250
  public static var closeGraceDays: Int { moneyRules.closeGraceDays }
  public static var pendingHoldDays: Int { moneyRules.pendingHoldDays }
  public static var coverageThreshold: Thousandths { moneyRules.coverageThreshold }

  private static var moneyRules: MoneyRules { Ruleset.current.money ?? .v2 }
}
