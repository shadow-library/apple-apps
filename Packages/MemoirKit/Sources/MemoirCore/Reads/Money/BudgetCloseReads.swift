import Foundation
import ShadowCore
import ShadowStore

/// Why a close puts nothing into savings.
public enum CloseDepositSkip: String, Sendable, Hashable {
  case trip
  /// The budget has fewer complete months than `BudgetThresholds.calibrationMonths` before the period.
  case calibrating
  case overOrUnscored = "over_or_unscored"
  /// Spending reached the deposit reference (`BudgetPeriodStanding.depositReferenceMinor`), or what was left of it rounds to nothing in home.
  case reachedReference = "reached_reference"
  /// The budget's currency had no recorded rate on or before the close day once the pending hold ended.
  case rateMissing = "rate_missing"
  case unconvertible
}

/// What a close puts into savings, in the home currency.
public enum CloseDeposit: Sendable, Hashable {
  /// Above zero; `rate` is the price of one unit of the budget's currency in home that converted it, nil for a budget in the home currency.
  case amount(Int64, rate: DecimalText?)
  case skipped(CloseDepositSkip)
  /// Another device's close already wrote the period's deposit record, which is final: the close takes its amount and its frozen spending and limit.
  case recorded(SavingsDeposit)

  public var amountMinor: Int64 {
    switch self {
    case .amount(let minor, _): minor
    case .skipped: 0
    case .recorded(let deposit): max(0, deposit.amountMinor)
    }
  }
}

/// A budget period that has ended and may be closed now, with what its close judges: the outcome, the spending and limit it freezes and the deposit.
public struct ClosablePeriod: Sendable, Hashable, Identifiable {
  public let budget: LiveBudget
  public let period: BudgetPeriod
  public let outcome: BudgetCloseOutcome
  /// The period's covered days out of all its days.
  public let coverage: LoggingCoverage
  /// In the budget's currency: the expenses logged before the earliest close moment (`BudgetBook.logged`), or the deposit record's snapshot.
  public let spentMinor: Int64
  public let limitMinor: Int64
  public let medianExpenseMinor: Int64?
  /// The typical month the outcome compared against; nil for a trip or a calibrating budget.
  public let typicalMonthMinor: Int64?
  /// Expenses left out of `spentMinor` because they still wait for a rate after the hold, or cannot convert.
  public let excluded: PendingConversions
  public let deposit: CloseDeposit
  public let home: CurrencyCode
  /// The account's day the period was judged on, which the deposit records as its close day.
  public let closedOn: LocalDate
  /// The instant it was judged at; the close writes what the vault reads at this instant.
  public let judgedAtMillis: Int64

  public var key: MoneyCloseKey { MoneyCloseKey(budget: budget.id, periodStart: period.start) }
  public var id: MoneyCloseKey { key }

  /// Whether the close command says it deposited: only a close within its limit, with a deposit above zero.
  public var deposited: Bool {
    switch outcome {
    case .within, .withinTypical: deposit.amountMinor > 0
    case .over10, .over25, .overMore, .unscored: false
    }
  }

  func snapshot(command: UUID) -> SavingsDeposit {
    if case .recorded(let deposit) = deposit { return deposit }
    var rate: DecimalText?
    if case .amount(_, let converted) = deposit { rate = converted }
    return SavingsDeposit(
      amountMinor: deposit.amountMinor, currency: home, rate: rate, closedOn: closedOn, command: command, spentMinor: spentMinor, limitMinor: limitMinor,
      medianExpenseMinor: medianExpenseMinor)
  }
}

/// Which budget periods can close, and how each would close.
///
/// A period closes once it has ended and its earliest close moment (`BudgetBook.earliestCloseMillis`, the moment a month's history stops counting newly
/// logged expenses) has passed. While an expense of the period waits for a rate, or a foreign budget's deposit has no rate to convert at, it waits until
/// `BudgetThresholds.pendingHoldDays` days after that moment, then closes without them: the expenses are left out and the deposit is zero. An expense that
/// cannot convert never holds a close.
///
/// Only live budgets with a limit close: a budget without one is never scored. Home closes every month it may, whatever it counted, so not logging is
/// judged unscored and never cheaper than overspending, and a month of "no spend" closes within its typical month. Any other budget's period none of
/// whose expenses counted (none assigned to it, or all of them left out) is never closed and earns neither reward nor penalty (D37): a currency's
/// budget in a month spent at home is not judged, and an empty budget cannot farm rewards. Nothing closes while replay is halted, nor before the
/// account has `moneyScoredFrom` (D23). A monthly
/// budget closes the months starting on or after both that day and the day it was created (the first month that lies wholly after it, as its history
/// counts months); a trip closes once, when it starts on or after that day and at most `BudgetEdits.tripBackdatingDays` before the day it was created.
/// A period replay already holds a close for is done, even when this build can no longer read its command; one whose deposit record arrived without its
/// close is closed from that record's snapshot.
public enum BudgetCloseReads {
  /// The periods that can close at `now` on the account's day `today`, oldest first, then in the budgets' order.
  public static func closable(in stores: MemoirStores, today: LocalDate, now: Date) async throws(MemoirReadError) -> [ClosablePeriod] {
    let nowMillis = try millis(now)
    return try await readCall { () async throws(StoreError) in
      try await stores.main.read { transaction in closable(try BudgetBook.load(from: transaction), today: today, nowMillis: nowMillis) }
    }
  }

  public static func closable(in transaction: ReadTransaction, today: LocalDate, now: Date) throws(MemoirReadError) -> [ClosablePeriod] {
    closable(try BudgetBook.load(from: transaction), today: today, nowMillis: try millis(now))
  }

  static func closable(_ book: BudgetBook, today: LocalDate, nowMillis: Int64) -> [ClosablePeriod] {
    guard book.replayHalt == nil, let converter = book.converter, let scoredFrom = book.settings?.moneyScoredFrom else { return [] }
    var found = [(order: Int, period: ClosablePeriod)]()
    for (order, budget) in book.liveBudgets(today: today).enumerated() {
      for period in candidates(of: budget, scoredFrom: scoredFrom, today: today) {
        guard let closable = evaluate(budget, period: period, book: book, converter: converter, today: today, nowMillis: nowMillis) else { continue }
        found.append((order, closable))
      }
    }
    return found.sorted { first, second in
      first.period.period.start != second.period.period.start ? first.period.period.start < second.period.period.start : first.order < second.order
    }.map(\.period)
  }

  /// The ended periods of a budget its scoring rules admit, oldest first.
  static func candidates(of budget: LiveBudget, scoredFrom: LocalDate, today: LocalDate) -> [BudgetPeriod] {
    switch budget.record.period {
    case .monthly:
      var periods = [BudgetPeriod]()
      var start = firstMonth(onOrAfter: max(scoredFrom, budget.record.createdOn))
      while let monthStart = start, let span = DateSpan.month(of: monthStart), span.end < today {
        periods.append(BudgetPeriod(span: span))
        start = monthStart.adding(months: 1)
      }
      return periods
    case .trip(let from, let through):
      guard let backdated = budget.record.createdOn.adding(days: -BudgetEdits.tripBackdatingDays), from >= max(scoredFrom, backdated), through < today,
        let span = DateSpan(start: from, end: through)
      else { return [] }
      return [BudgetPeriod(span: span)]
    }
  }

  /// How `period` would close now; nil while replay holds a close for it, before its earliest close moment, during a hold, without a limit, or, for a
  /// budget other than Home, with no expense counted.
  static func evaluate(_ budget: LiveBudget, period: BudgetPeriod, book: BudgetBook, converter: BudgetConverter, today: LocalDate, nowMillis: Int64) -> ClosablePeriod? {
    let key = MoneyCloseKey(budget: budget.id, periodStart: period.start)
    guard !book.closedPeriods.contains(key), let earliest = book.earliestCloseMillis(of: period), nowMillis >= earliest else { return nil }
    let recorded = book.deposits[key]
    guard let limit = recorded == nil ? budget.limitMinor(for: period) : recorded?.limitMinor else { return nil }
    let logged = book.logged(budget, in: period, converter: converter)
    let spent = recorded?.spentMinor ?? logged.spend.spentMinor
    let history = budget.record.period == .monthly ? BudgetHistory.make(budget: budget, before: period, today: today, book: book, converter: converter) : nil
    var typical: Int64?
    if case .known(let month, _)? = history?.typical { typical = month }
    let coverage = LoggingCoverage.of(period, today: today, covered: book.coveredDays)
    let outcome = outcome(spentMinor: spent, limitMinor: limit, coverage: coverage, typicalMonthMinor: typical, drewOnSavings: logged.spend.drewOnSavings)
    let deposit: CloseDeposit
    if let recorded {
      deposit = .recorded(recorded)
    } else {
      deposit = self.deposit(budget, outcome: outcome, spentMinor: spent, limitMinor: limit, history: history, converter: converter, today: today)
      if logged.spend.pending.awaitingRate > 0 || deposit == .skipped(.rateMissing) {
        guard let held = book.earliestCloseDay(of: period)?.adding(days: BudgetThresholds.pendingHoldDays).flatMap(book.startMillis(of:)), nowMillis >= held
        else { return nil }
      }
      guard budget.isHome || logged.spend.counted > 0 else { return nil }
    }
    return ClosablePeriod(
      budget: budget, period: period, outcome: outcome, coverage: coverage, spentMinor: spent, limitMinor: limit,
      medianExpenseMinor: recorded == nil ? logged.medianExpenseMinor : recorded?.medianExpenseMinor, typicalMonthMinor: typical,
      excluded: recorded == nil ? logged.spend.pending : .none, deposit: deposit, home: converter.home, closedOn: today, judgedAtMillis: nowMillis)
  }

  /// Unscored below the coverage threshold; over the limit by at most `BudgetThresholds.overSlightThousandths` or `overModerateThousandths` of it, or by
  /// more (any spending over a zero limit); within it and at most the typical month when there is one and no expense drew on savings; else within.
  static func outcome(spentMinor: Int64, limitMinor: Int64, coverage: LoggingCoverage, typicalMonthMinor: Int64?, drewOnSavings: Bool) -> BudgetCloseOutcome {
    guard Int128(coverage.coveredDays) * 1000 >= Int128(coverage.daysSoFar) * Int128(BudgetThresholds.coverageThreshold.thousandths) else { return .unscored }
    let spent = Int128(spentMinor)
    let limit = Int128(limitMinor)
    if spent > limit {
      let over = (spent - limit) * 1000
      if over <= limit * Int128(BudgetThresholds.overSlightThousandths) { return .over10 }
      if over <= limit * Int128(BudgetThresholds.overModerateThousandths) { return .over25 }
      return .overMore
    }
    if let typical = typicalMonthMinor, !drewOnSavings, spentMinor <= typical { return .withinTypical }
    return .within
  }

  /// A monthly budget within its limit and past calibration deposits its reference less what it spent, converted into home at its currency's newest
  /// recorded rate on or before the close day, halves up.
  private static func deposit(
    _ budget: LiveBudget, outcome: BudgetCloseOutcome, spentMinor: Int64, limitMinor: Int64, history: BudgetHistory?, converter: BudgetConverter, today: LocalDate
  ) -> CloseDeposit {
    guard budget.record.period == .monthly else { return .skipped(.trip) }
    guard outcome == .within || outcome == .withinTypical else { return .skipped(.overOrUnscored) }
    guard let reference = BudgetPeriodStanding.depositReference(limitMinor: limitMinor, history: history) else { return .skipped(.calibrating) }
    let left = Int64(clamping: Int128(reference) - Int128(spentMinor))
    guard left > 0 else { return .skipped(.reachedReference) }
    let rate = budget.currency == converter.home ? nil : converter.latestRate(of: budget.currency, onOrBefore: today)?.rate
    switch HomeConverter.convert(MoneyAmount(amountMinor: left, currency: budget.currency), home: converter.home, rate: rate) {
    case .converted(let minor): return minor > 0 ? .amount(minor, rate: rate) : .skipped(.reachedReference)
    case .awaitingRate: return .skipped(.rateMissing)
    case .unconvertible: return .skipped(.unconvertible)
    }
  }

  private static func firstMonth(onOrAfter date: LocalDate) -> LocalDate? {
    guard let start = LocalDate(year: date.year, month: date.month, day: 1) else { return nil }
    return start == date ? start : start.adding(months: 1)
  }

  private static func millis(_ now: Date) throws(MemoirReadError) -> Int64 {
    guard let millis = Int64(exactly: (now.timeIntervalSince1970 * 1000).rounded(.down)) else { throw .finance(.dateOutOfRange) }
    return millis
  }
}
