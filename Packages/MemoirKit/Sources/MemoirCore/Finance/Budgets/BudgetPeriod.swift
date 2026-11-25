/// The span of a budget that holds a date: the calendar month for a monthly budget, the trip's own dates for a trip, none for a date outside a trip.
public struct BudgetPeriod: Hashable, Sendable {
  public let span: DateSpan

  public init(span: DateSpan) {
    self.span = span
  }

  public static func containing(_ date: LocalDate, of kind: BudgetPeriodKind) -> BudgetPeriod? {
    switch kind {
    case .monthly:
      return DateSpan.month(of: date).map(BudgetPeriod.init)
    case .trip(let from, let through):
      guard let span = DateSpan(start: from, end: through), span.contains(date) else { return nil }
      return BudgetPeriod(span: span)
    }
  }

  public var start: LocalDate { span.start }
  public var end: LocalDate { span.end }
}

/// When an edited amount takes effect: at once, for the whole of the current period (dropping a change that was waiting), or from a later day, the
/// amount in force until then kept.
public enum BudgetStagedChange: Hashable, Sendable {
  case applies(dropping: StagedAmount?)
  case staged(StagedAmount, keeping: Int64?)

  init(from old: BudgetStaging, to new: BudgetStaging, today: LocalDate) {
    if let pending = new.pending(on: today) {
      self = .staged(pending, keeping: new.value(on: today))
    } else {
      self = .applies(dropping: old.pending(on: today))
    }
  }
}

/// The two slots a staged amount lives in: the amount in force and one change that takes effect from a later day. A staged change whose day has come
/// is applied when read, never by a write.
struct BudgetStaging: Hashable, Sendable {
  var base: Int64?
  var staged: StagedAmount?

  func value(on date: LocalDate) -> Int64? {
    if let staged, staged.from <= date { return staged.amountMinor }
    return base
  }

  func pending(on date: LocalDate) -> StagedAmount? {
    guard let staged, staged.from > date else { return nil }
    return staged
  }

  func latest(on date: LocalDate) -> Int64? {
    pending(on: date)?.amountMinor ?? value(on: date)
  }

  /// A raise above the limit the month opened with waits for the next month. A lowering, setting the limit back to the one in force, or a raise up to
  /// the opening limit applies to the whole current month and drops a pending raise, so a mistaken lowering can be undone. Every accepted change
  /// leaves last month's limit as it was for its close, so a raise above the opening limit in a month whose limit already changed is refused: two
  /// slots cannot hold last month's, this month's and next month's limits.
  func monthlyLimit(to limit: Int64, today: LocalDate) throws(FinanceError) -> BudgetStaging {
    let month = try Self.monthStart(of: today)
    let current = value(on: today)
    let previous = month.adding(days: -1).map { value(on: $0) } ?? current
    let restoresOpening = previous.map { limit <= $0 } ?? false
    if let current, limit > current, !restoresOpening {
      guard previous == current else { throw .limitChangedThisMonth }
      return BudgetStaging(base: current, staged: StagedAmount(amountMinor: limit, from: try Self.nextMonthStart(of: today)))
    }
    guard previous != limit else { return BudgetStaging(base: limit, staged: nil) }
    return BudgetStaging(base: previous, staged: StagedAmount(amountMinor: limit, from: month))
  }

  func tripLimit(to limit: Int64, startingOn start: LocalDate, today: LocalDate) throws(FinanceError) -> BudgetStaging {
    if let current = value(on: today), limit > current, today >= start { throw .tripLimitLocked }
    return BudgetStaging(base: limit, staged: nil)
  }

  /// A lower threshold lets more expenses draw on savings, so it waits for the next month; a higher one, or none, which returns to the automatic
  /// threshold, applies at once and drops a pending lowering.
  func oneOff(to threshold: Int64?, today: LocalDate) throws(FinanceError) -> BudgetStaging {
    guard let threshold else { return BudgetStaging(base: nil, staged: nil) }
    let current = value(on: today)
    if let current, threshold >= current { return BudgetStaging(base: threshold, staged: nil) }
    return BudgetStaging(base: current, staged: StagedAmount(amountMinor: threshold, from: try Self.nextMonthStart(of: today)))
  }

  static func monthStart(of date: LocalDate) throws(FinanceError) -> LocalDate {
    guard let start = LocalDate(year: date.year, month: date.month, day: 1) else { throw .dateOutOfRange }
    return start
  }

  static func nextMonthStart(of date: LocalDate) throws(FinanceError) -> LocalDate {
    guard let next = try monthStart(of: date).adding(months: 1) else { throw .dateOutOfRange }
    return next
  }
}
