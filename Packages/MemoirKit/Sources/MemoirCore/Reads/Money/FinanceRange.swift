/// The stretch a Money screen sums over.
public enum FinanceRange: String, CaseIterable, Sendable {
  case week
  case month
  case year

  /// memoir-web `financePeriod` (`lib/data/finance.rules.ts:226`): the calendar year or month, or the Monday-to-Sunday week holding `today`.
  public func period(containing today: LocalDate) -> DateSpan? {
    switch self {
    case .year:
      guard let first = LocalDate(year: today.year, month: 1, day: 1), let last = LocalDate(year: today.year, month: 12, day: 31) else { return nil }
      return DateSpan(start: first, end: last)
    case .month:
      return DateSpan.month(of: today)
    case .week:
      return DateSpan.mondayWeek(of: today)
    }
  }

  /// memoir-web `previousStretch` (`finance.rules.ts:236-243`): the previous period from its start up to the same point, the 1st to the 14th of last
  /// month when today is the 14th, clamped to the shorter month's end.
  public func previousStretch(before today: LocalDate) -> DateSpan? {
    switch self {
    case .week:
      guard let start = period(containing: today)?.start.adding(days: -7), let end = today.adding(days: -7) else { return nil }
      return DateSpan(start: start, end: end)
    case .year:
      let year = today.year - 1
      guard let first = LocalDate(year: year, month: 1, day: 1), let last = LocalDate.clampedToMonthEnd(year: year, month: today.month, day: today.day)
      else { return nil }
      return DateSpan(start: first, end: last)
    case .month:
      let year = today.month == 1 ? today.year - 1 : today.year
      let month = today.month == 1 ? 12 : today.month - 1
      guard let first = LocalDate(year: year, month: month, day: 1), let last = LocalDate.clampedToMonthEnd(year: year, month: month, day: today.day) else {
        return nil
      }
      return DateSpan(start: first, end: last)
    }
  }
}

public enum SpendDelta {
  /// memoir-web `spendDelta` (`finance.rules.ts:249`): the change against the previous stretch as an exact fraction; `nil` when the previous stretch
  /// spent nothing to compare with, or when the change does not fit in `Int` terms.
  public static func fraction(current: Int64, previous: Int64) -> Fraction? {
    guard previous > 0 else { return nil }
    return Fraction.exactly(Int128(current) - Int128(previous), Int128(previous))
  }
}
