import Foundation
import ShadowCore
import ShadowStore

/// Where a complete month's spending and limit come from.
public enum RecordedMonthSource: Sendable, Hashable {
  /// The close's deposit record, which froze what the close judged, so no later edit of the month's expenses changes it.
  case closeSnapshot(SavingsDeposit)
  /// The expenses logged (`loggedAtMillis`) before `cutoffMillis`: the close's instant once replay holds a close, else the end of the last grace day.
  /// Everything else is current state, so a deletion, a refund or an override moving an expense out after the cutoff lowers the month, and an override
  /// moving in an expense logged before it raises it.
  case logged(cutoffMillis: Int64?, spend: BudgetSpend)
}

/// A complete month of a monthly budget, as the typical month reads it.
public struct RecordedMonth: Sendable, Hashable {
  public let period: BudgetPeriod
  public let isClosed: Bool
  public let source: RecordedMonthSource
  public let spentMinor: Int64
  /// The close's snapshot when there is one. Otherwise the limit as read today: a budget keeps only the limit in force and one staged change, so after a
  /// later month's change rewrites them, a month two or more back reads the limit of a later month (`BudgetStaging.monthlyLimit`); only the month just
  /// before the current one is kept exact.
  public let limitMinor: Int64?
  /// The median of the month's positive expenses, whole amounts in the budget's currency: the close's snapshot when there is one, else over the expenses
  /// logged before the cutoff; nil without one.
  public let medianExpenseMinor: Int64?
}

public enum BudgetTypical: Sendable, Hashable {
  /// Fewer complete months than `BudgetThresholds.calibrationMonths`.
  case calibrating(completeMonths: Int)
  /// The median of the months' spending, and the typical single expense: the median of the months' `medianExpenseMinor` (whole amounts, savings
  /// included, refunded ones left out), so an edit after a close never moves a closed month's part; nil when no month holds an expense.
  case known(monthMinor: Int64, singleExpenseMinor: Int64?)
}

/// The up to `BudgetThresholds.typicalMonths` complete months of a monthly budget before a period and before the month holding `today`, oldest first. A
/// month counts once it lies wholly on or after the day the budget was created, so the month it was created in counts only when that was its first day.
public struct BudgetHistory: Sendable, Hashable {
  public let months: [RecordedMonth]
  public let typical: BudgetTypical

  static func make(budget: LiveBudget, before period: BudgetPeriod, today: LocalDate, book: BudgetBook, converter: BudgetConverter) -> BudgetHistory? {
    guard budget.record.period == .monthly else { return nil }
    var months = [RecordedMonth]()
    let before = min(period.start, today)
    var start = LocalDate(year: before.year, month: before.month, day: 1)?.adding(months: -1)
    while months.count < BudgetThresholds.typicalMonths, let monthStart = start, monthStart >= budget.record.createdOn, let span = DateSpan.month(of: monthStart) {
      let month = BudgetPeriod(span: span)
      let key = MoneyCloseKey(budget: budget.id, periodStart: month.start)
      let cutoff = book.cutoffMillis(of: budget.id, period: month)
      let logged = book.expenses(of: budget.id, in: month).filter { expense in cutoff.map { expense.loggedAtMillis < $0 } ?? true }
      let isClosed = book.closeInstants[key] != nil || book.deposits[key] != nil
      if let deposit = book.deposits[key] {
        months.append(
          RecordedMonth(
            period: month, isClosed: isClosed, source: .closeSnapshot(deposit), spentMinor: deposit.spentMinor, limitMinor: deposit.limitMinor,
            medianExpenseMinor: deposit.medianExpenseMinor))
      } else {
        let spend = BudgetSpend.tally(logged) { converter.amount(of: $0, in: budget.currency) }
        months.append(
          RecordedMonth(
            period: month, isClosed: isClosed, source: .logged(cutoffMillis: cutoff, spend: spend), spentMinor: spend.spentMinor,
            limitMinor: budget.limitMinor(for: month),
            medianExpenseMinor: median(logged.compactMap { expense in converter.amount(of: expense, in: budget.currency).minor.flatMap { $0 > 0 ? $0 : nil } })))
      }
      start = monthStart.adding(months: -1)
    }
    months.reverse()
    guard months.count >= BudgetThresholds.calibrationMonths, let typical = median(months.map(\.spentMinor)) else {
      return BudgetHistory(months: months, typical: .calibrating(completeMonths: months.count))
    }
    return BudgetHistory(months: months, typical: .known(monthMinor: typical, singleExpenseMinor: median(months.compactMap(\.medianExpenseMinor))))
  }

  /// The middle value; of an even count, the mean of the two middle ones, halves up.
  static func median(_ values: [Int64]) -> Int64? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    guard sorted.count.isMultiple(of: 2) else { return sorted[middle] }
    return Int64(clamping: Exact.roundHalfUp(Int128(sorted[middle - 1]) + Int128(sorted[middle]), 2))
  }
}

/// The smallest amount an expense counts as a one-off at, the only kind that may draw on savings, and where it comes from: the owner's own threshold; else
/// `oneOffMultiple` times the typical single expense; else (calibrating, a trip, or no expense in the months) `oneOffLimitThousandths` of the limit,
/// halves up; unavailable without any of them. Each is read as of the expense's date or today, whichever is earlier, so a future-dated expense never
/// takes a staged threshold or limit early, nor a month that has not ended.
public enum OneOffThreshold: Sendable, Hashable {
  case owner(Int64)
  case typicalExpense(Int64)
  case limitShare(Int64)
  case unavailable

  public var minor: Int64? {
    switch self {
    case .owner(let minor), .typicalExpense(let minor), .limitShare(let minor): minor
    case .unavailable: nil
    }
  }

  static func resolve(budget: LiveBudget, period: BudgetPeriod, on date: LocalDate, today: LocalDate, history: BudgetHistory?) -> OneOffThreshold {
    let asOf = min(date, today)
    if let owner = budget.oneOffFromMinor(on: asOf) { return .owner(owner) }
    if case .known(_, let single?) = history?.typical { return .typicalExpense(Int64(clamping: Int128(single) * Int128(BudgetThresholds.oneOffMultiple))) }
    guard let limit = budget.limitMinor(on: min(period.end, today)) else { return .unavailable }
    return .limitShare(Int64(clamping: Exact.roundHalfUp(Int128(limit) * Int128(BudgetThresholds.oneOffLimitThousandths), 1000)))
  }
}

extension BudgetBook {
  /// The complete months of a monthly budget before `period` (the month a close judges, say) that ended before `today`; nil for a trip or before the vault
  /// has settings.
  public func history(of budget: LiveBudget, before period: BudgetPeriod, today: LocalDate) -> BudgetHistory? {
    converter.flatMap { BudgetHistory.make(budget: budget, before: period, today: today, book: self, converter: $0) }
  }

  /// The one-off threshold for an expense of `budget` dated `date`; unavailable outside a trip's dates or before the vault has settings.
  public func oneOffThreshold(of budget: LiveBudget, on date: LocalDate, today: LocalDate) -> OneOffThreshold {
    guard let period = budget.period(containing: date) else { return .unavailable }
    return OneOffThreshold.resolve(budget: budget, period: period, on: date, today: today, history: history(of: budget, before: period, today: today))
  }
}
