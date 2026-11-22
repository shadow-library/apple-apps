/// An inclusive run of civil days.
public struct DateSpan: Sendable, Hashable {
  public let start: LocalDate
  public let end: LocalDate

  public init?(start: LocalDate, end: LocalDate) {
    guard start <= end else { return nil }
    self.start = start
    self.end = end
  }

  /// `count` days ending on `last`, as memoir-web's `daysBack` lists them.
  public static func trailing(_ count: Int, endingOn last: LocalDate) -> DateSpan? {
    guard count >= 1, let first = last.adding(days: 1 - count) else { return nil }
    return DateSpan(start: first, end: last)
  }

  public static func month(of date: LocalDate) -> DateSpan? {
    guard let first = LocalDate(year: date.year, month: date.month, day: 1),
      let last = LocalDate(year: date.year, month: date.month, day: LocalDate.daysInMonth(year: date.year, month: date.month))
    else { return nil }
    return DateSpan(start: first, end: last)
  }

  /// The Monday-to-Sunday week holding `date`, as Planning, Review and the Crown count weeks.
  public static func mondayWeek(of date: LocalDate) -> DateSpan? {
    guard let monday = date.startOfMondayWeek, let sunday = monday.adding(days: 6) else { return nil }
    return DateSpan(start: monday, end: sunday)
  }

  public var dayCount: Int { end.days(since: start) + 1 }

  public var dates: [LocalDate] {
    (0..<dayCount).compactMap { start.adding(days: $0) }
  }

  public func contains(_ date: LocalDate) -> Bool {
    start <= date && date <= end
  }
}

/// One day's value in a series; `nil` is a day with nothing logged, which memoir-web shows as blank rather than zero.
public struct DayValue<Value: Sendable & Hashable>: Sendable, Hashable {
  public let date: LocalDate
  public let value: Value?

  public init(date: LocalDate, value: Value?) {
    self.date = date
    self.value = value
  }
}
