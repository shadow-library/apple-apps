public enum WeekdayOrdinal: Sendable, Hashable, CaseIterable {
  case first
  case second
  case third
  case fourth
  case last
}

extension LocalDate {
  static let monthsPerYear = 12
  static let daysPerWeek = 7
  static let mondayEpochOffset = 3

  public static func clampedToMonthEnd(year: Int, month: Int, day: Int) -> LocalDate? {
    guard (1...12).contains(month), day >= 1 else { return nil }
    return LocalDate(year: year, month: month, day: min(day, daysInMonth(year: year, month: month)))
  }

  static func clampedToMonthEnd(monthIndex: Int, day: Int) -> LocalDate? {
    guard (earliest.monthIndex...latest.monthIndex).contains(monthIndex) else { return nil }
    return clampedToMonthEnd(year: floorDivide(monthIndex, monthsPerYear), month: floorModulo(monthIndex, monthsPerYear) + 1, day: day)
  }

  public var monthIndex: Int { year * Self.monthsPerYear + month - 1 }

  public func adding(months: Int) -> LocalDate? {
    let (shifted, overflow) = monthIndex.addingReportingOverflow(months)
    return overflow ? nil : Self.clampedToMonthEnd(monthIndex: shifted, day: day)
  }

  public var mondayWeekIndex: Int { Self.floorDivide(daysSinceEpoch + Self.mondayEpochOffset, Self.daysPerWeek) }

  public var startOfMondayWeek: LocalDate? { LocalDate(daysSinceEpoch: mondayDay) }

  public func weeks(since other: LocalDate) -> Int {
    mondayWeekIndex - other.mondayWeekIndex
  }

  public static func nthWeekday(_ weekday: Weekday, _ ordinal: WeekdayOrdinal, year: Int, month: Int) -> LocalDate? {
    guard let first = LocalDate(year: year, month: month, day: 1), let last = LocalDate(year: year, month: month, day: daysInMonth(year: year, month: month))
    else { return nil }
    let step: Int
    switch ordinal {
    case .last: return LocalDate(daysSinceEpoch: last.daysSinceEpoch - floorModulo(last.weekday.rawValue - weekday.rawValue, daysPerWeek))
    case .first: step = 0
    case .second: step = 1
    case .third: step = 2
    case .fourth: step = 3
    }
    return LocalDate(daysSinceEpoch: first.daysSinceEpoch + floorModulo(weekday.rawValue - first.weekday.rawValue, daysPerWeek) + step * daysPerWeek)
  }

  var mondayDay: Int { daysSinceEpoch - (weekday.rawValue - 1) }

  static func floorModulo(_ value: Int, _ modulus: Int) -> Int {
    value - floorDivide(value, modulus) * modulus
  }
}
