import Foundation
import ShadowCore
import ShadowStore

/// Where a budget's period stands against the account's day: a trip before it starts, the period that holds the day (a monthly budget's always does),
/// or a trip that has ended. Days count today.
public enum BudgetPeriodPhase: Sendable, Hashable {
  case upcoming(startsInDays: Int)
  case current(daysElapsed: Int, daysLeft: Int)
  case ended

  public var daysLeft: Int? {
    guard case .current(_, let daysLeft) = self else { return nil }
    return daysLeft
  }

  static func of(_ period: BudgetPeriod, today: LocalDate) -> BudgetPeriodPhase {
    if today < period.start { return .upcoming(startsInDays: period.start.days(since: today)) }
    if today > period.end { return .ended }
    return .current(daysElapsed: today.days(since: period.start) + 1, daysLeft: period.end.days(since: today) + 1)
  }
}

public enum BudgetRisk: String, Sendable, Hashable {
  /// Spending has reached `BudgetThresholds.atRiskThousandths` of the limit.
  case mostlySpent = "mostly_spent"
  /// Spending so far, carried on at the same rate per day, ends the period over the limit.
  case projectedOver = "projected_over"
}

public enum BudgetPace: Sendable, Hashable {
  case noLimit
  case onTrack
  case atRisk(BudgetRisk)
  case over(byMinor: Int64)

  /// Nothing spent against a zero limit is on track; spending over the limit is over before it is at risk.
  static func of(spentMinor: Int64, limitMinor: Int64?, phase: BudgetPeriodPhase, days: Int) -> BudgetPace {
    guard let limit = limitMinor else { return .noLimit }
    let spent = Int128(spentMinor)
    if spent > Int128(limit) { return .over(byMinor: Int64(clamping: spent - Int128(limit))) }
    if spent > 0 && spent * 1000 >= Int128(limit) * Int128(BudgetThresholds.atRiskThousandths) { return .atRisk(.mostlySpent) }
    if let elapsed = elapsedDays(phase, days: days), elapsed > 0, spent * Int128(days) > Int128(limit) * Int128(elapsed) { return .atRisk(.projectedOver) }
    return .onTrack
  }

  static func elapsedDays(_ phase: BudgetPeriodPhase, days: Int) -> Int? {
    switch phase {
    case .upcoming: nil
    case .current(let elapsed, _): elapsed
    case .ended: days
    }
  }
}

/// A period's spending in the budget's currency. Each expense counts without the part it drew on savings (`fromSavingsMinor`, clamped to the amount, as
/// a merge can leave it above a lowered amount), and only that part is converted. Expenses still waiting for a rate, and those that cannot convert or
/// would carry the sum past `Int64`, add nothing and are counted apart.
public struct BudgetSpend: Sendable, Hashable {
  public static let none = BudgetSpend(spentMinor: 0, counted: 0, pending: .none, drewOnSavings: false)

  public let spentMinor: Int64
  /// The expenses whose amount is in `spentMinor`.
  public let counted: Int
  public let pending: PendingConversions
  /// Whether any of the period's expenses drew on savings.
  public let drewOnSavings: Bool

  static func tally(_ expenses: [ExpenseRecord], amount: (ExpenseRecord) -> BudgetAmount) -> BudgetSpend {
    var total: Int64 = 0
    var counted = 0
    var awaiting = 0
    var unconvertible = 0
    var currencies = Set<String>()
    var drew = false
    for expense in expenses {
      if expense.savingsPortionMinor > 0 { drew = true }
      let portion = expense.budgetPortion
      guard portion.amountMinor != 0 else { continue }
      switch amount(portion) {
      case .converted(let minor):
        let (sum, overflow) = total.addingReportingOverflow(minor)
        if overflow {
          unconvertible += 1
        } else {
          total = sum
          counted += 1
        }
      case .awaitingRate:
        awaiting += 1
        currencies.insert(expense.currency.code)
      case .unconvertible:
        unconvertible += 1
      }
    }
    return BudgetSpend(
      spentMinor: total, counted: counted,
      pending: PendingConversions(awaitingRate: awaiting, unconvertible: unconvertible, currencies: currencies.sorted().compactMap(CurrencyCode.init)), drewOnSavings: drew)
  }
}

/// The days of a period so far that replay found covered (an expense logged for the day or "no spend", within the late window), out of the period's days
/// up to today: none before a trip starts, all of them once it has ended.
public struct LoggingCoverage: Sendable, Hashable {
  public let coveredDays: Int
  public let daysSoFar: Int

  static func of(_ period: BudgetPeriod, today: LocalDate, covered: Set<LocalDate>) -> LoggingCoverage {
    guard today >= period.start else { return LoggingCoverage(coveredDays: 0, daysSoFar: 0) }
    guard let span = DateSpan(start: period.start, end: min(today, period.end)) else { return LoggingCoverage(coveredDays: 0, daysSoFar: 0) }
    return LoggingCoverage(coveredDays: covered.count { span.contains($0) }, daysSoFar: span.dayCount)
  }
}

/// One live budget's current period: for a monthly budget the calendar month holding the account's day, for a trip its own dates, before, during or
/// after them.
public struct BudgetPeriodStanding: Sendable, Hashable, Identifiable {
  public let budget: LiveBudget
  public let period: BudgetPeriod
  public let phase: BudgetPeriodPhase
  /// The limit in force on the period's last day (`LiveBudget.limitMinor(for:)`), Home's falling back to the account's monthly budget; nil without one.
  public let limitMinor: Int64?
  /// A limit change staged for a later day.
  public let pendingLimit: StagedAmount?
  public let spend: BudgetSpend
  /// The limit less what was spent, below zero once over; nil without a limit.
  public let leftMinor: Int64?
  /// What the period would end at spending as it has per day so far, halves up; nil before a trip starts.
  public let projectedMinor: Int64?
  public let pace: BudgetPace
  /// What is left spread over the days left, today included, rounded down, so spending it never goes over: over the whole trip before it starts, nil
  /// once it has ended, over the limit or without one.
  public let safePerDayMinor: Int64?
  public let coverage: LoggingCoverage
  /// Monthly budgets only: the complete months before this one.
  public let history: BudgetHistory?
  public let oneOff: OneOffThreshold

  public var id: UUID { budget.id }

  init(budget: LiveBudget, period: BudgetPeriod, today: LocalDate, book: BudgetBook, converter: BudgetConverter) {
    let phase = BudgetPeriodPhase.of(period, today: today)
    let limit = budget.limitMinor(for: period)
    let spend = BudgetSpend.tally(book.expenses(of: budget.id, in: period)) { converter.amount(of: $0, in: budget.currency) }
    let history = BudgetHistory.make(budget: budget, before: period, today: today, book: book, converter: converter)
    self.budget = budget
    self.period = period
    self.phase = phase
    limitMinor = limit
    pendingLimit = budget.pendingLimit(on: today)
    self.spend = spend
    leftMinor = limit.map { Int64(clamping: Int128($0) - Int128(spend.spentMinor)) }
    projectedMinor = BudgetPace.elapsedDays(phase, days: period.span.dayCount).flatMap { elapsed in
      elapsed > 0 ? Int64(clamping: Exact.roundHalfUp(Int128(spend.spentMinor) * Int128(period.span.dayCount), Int128(elapsed))) : nil
    }
    pace = BudgetPace.of(spentMinor: spend.spentMinor, limitMinor: limit, phase: phase, days: period.span.dayCount)
    safePerDayMinor = Self.safePerDay(left: leftMinor, pace: pace, phase: phase, days: period.span.dayCount)
    coverage = LoggingCoverage.of(period, today: today, covered: book.coveredDays)
    self.history = history
    oneOff = OneOffThreshold.resolve(budget: budget, period: period, on: today, today: today, history: history)
  }

  private static func safePerDay(left: Int64?, pace: BudgetPace, phase: BudgetPeriodPhase, days: Int) -> Int64? {
    guard let left, pace != .noLimit else { return nil }
    if case .over = pace { return nil }
    let remaining: Int
    switch phase {
    case .upcoming: remaining = days
    case .current(_, let daysLeft): remaining = daysLeft
    case .ended: return nil
    }
    return remaining > 0 ? left / Int64(remaining) : nil
  }
}

/// Every live budget's current period, Home first and then by the day each was created, with the consolidated view.
public struct BudgetStandings: Sendable, Hashable {
  public let today: LocalDate
  /// The account's default currency, which the consolidated view totals in.
  public let home: CurrencyCode
  public let budgets: [BudgetPeriodStanding]
  public let consolidated: ConsolidatedStanding
  /// Budget records this version cannot read.
  public let unreadableBudgets: Int

  public var homeBudget: BudgetPeriodStanding? { budgets.first { $0.budget.isHome } }

  public func standing(of budget: UUID) -> BudgetPeriodStanding? {
    budgets.first { $0.id == budget }
  }

  /// Nil until the vault has its settings, which name the home currency.
  public static func make(_ book: BudgetBook, today: LocalDate) throws(FinanceError) -> BudgetStandings? {
    guard let converter = book.converter else { return nil }
    var standings = [BudgetPeriodStanding]()
    for budget in book.liveBudgets(today: today) {
      guard let period = currentPeriod(of: budget, today: today) else { throw .dateOutOfRange }
      standings.append(BudgetPeriodStanding(budget: budget, period: period, today: today, book: book, converter: converter))
    }
    return BudgetStandings(
      today: today, home: converter.home, budgets: standings, consolidated: ConsolidatedStanding.make(standings, book: book, converter: converter, today: today),
      unreadableBudgets: book.assignments.budgets.unreadable)
  }

  static func currentPeriod(of budget: LiveBudget, today: LocalDate) -> BudgetPeriod? {
    switch budget.record.period {
    case .monthly: DateSpan.month(of: today).map(BudgetPeriod.init)
    case .trip(let from, let through): DateSpan(start: from, end: through).map(BudgetPeriod.init)
    }
  }
}

extension ExpenseRecord {
  /// The part drawn on savings, clamped to the amount.
  var savingsPortionMinor: Int64 {
    min(max(fromSavingsMinor ?? 0, 0), max(amountMinor, 0))
  }

  /// The expense as its budget counts it: without the part drawn on savings.
  var budgetPortion: ExpenseRecord {
    var portion = self
    portion.amountMinor = amountMinor - savingsPortionMinor
    return portion
  }
}
