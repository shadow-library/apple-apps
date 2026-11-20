public enum MonthlyPattern: Sendable, Hashable {
  case dayOfMonth(Int)
  case nthWeekday(LocalDate.Weekday, WeekdayOrdinal)
}

public enum RecurrenceEnd: Sendable, Hashable {
  case never
  case count(Int)
  case until(LocalDate)
}

public struct RecurrenceOccurrence: Sendable, Hashable {
  public let date: LocalDate
  public let index: Int

  public init(date: LocalDate, index: Int) {
    self.date = date
    self.index = index
  }
}

public struct RecurrenceExpansion: Sendable, Hashable {
  public let occurrences: [RecurrenceOccurrence]
  /// The last raw occurrence at or before the window's end, excepted or not: the next expansion's cursor.
  public let cursor: RecurrenceOccurrence?
}

public struct RecurrenceRule: Sendable, Hashable {
  public enum Frequency: Sendable, Hashable {
    case daily
    case weekly(Set<LocalDate.Weekday>)
    case monthly(MonthlyPattern)
    case yearly
  }

  public let frequency: Frequency
  /// Every `interval` periods; values below 1 are read as 1.
  public let interval: Int
  /// The series' lower bound, an occurrence only when the pattern lands on it.
  public let startDate: LocalDate
  public let end: RecurrenceEnd
  /// An excepted date still takes its index, so it consumes a slot under a `.count` end.
  public let exceptions: Set<LocalDate>

  public init(frequency: Frequency, interval: Int = 1, startDate: LocalDate, end: RecurrenceEnd = .never, exceptions: Set<LocalDate> = []) throws(CalendarError) {
    switch frequency {
    case .weekly(let weekdays) where weekdays.isEmpty: throw .noWeekdays
    case .monthly(.dayOfMonth(let day)) where day < 1: throw .dayOfMonthOutOfRange(day)
    default: break
    }
    self.frequency = frequency
    self.interval = interval
    self.startDate = startDate
    self.end = end
    self.exceptions = exceptions
  }

  public func expand(from: LocalDate, through: LocalDate, resumingAt cursor: RecurrenceOccurrence? = nil) -> RecurrenceExpansion {
    guard from <= through else { return RecurrenceExpansion(occurrences: [], cursor: nil) }
    var occurrences: [RecurrenceOccurrence] = []
    var last: RecurrenceOccurrence?
    var raw = RawOccurrences(rule: self, anchor: anchor(for: cursor, notAfter: from))
    while let occurrence = raw.next(), isWithinEnd(occurrence), occurrence.date <= through {
      last = occurrence
      if occurrence.date < from || exceptions.contains(occurrence.date) { continue }
      occurrences.append(occurrence)
    }
    return RecurrenceExpansion(occurrences: occurrences, cursor: last)
  }

  public func occurs(on date: LocalDate, resumingAt cursor: RecurrenceOccurrence? = nil) -> Bool {
    !expand(from: date, through: date, resumingAt: cursor).occurrences.isEmpty
  }

  public func nextOccurrence(onOrAfter date: LocalDate, resumingAt cursor: RecurrenceOccurrence? = nil) -> RecurrenceOccurrence? {
    var raw = RawOccurrences(rule: self, anchor: anchor(for: cursor, notAfter: date))
    while let occurrence = raw.next(), isWithinEnd(occurrence) {
      if occurrence.date < date || exceptions.contains(occurrence.date) { continue }
      return occurrence
    }
    return nil
  }

  private var step: Int { max(1, interval) }

  private func anchor(for cursor: RecurrenceOccurrence?, notAfter limit: LocalDate) -> RecurrenceOccurrence {
    guard let cursor, cursor.index >= 0, cursor.date >= startDate, cursor.date <= limit else { return RecurrenceOccurrence(date: startDate, index: 0) }
    return cursor
  }

  private func isWithinEnd(_ occurrence: RecurrenceOccurrence) -> Bool {
    switch end {
    case .never: true
    case .count(let count): occurrence.index < max(0, count)
    case .until(let date): occurrence.date <= date
    }
  }

  fileprivate func period(of date: LocalDate) -> Int {
    switch frequency {
    case .daily: date.daysSinceEpoch
    case .weekly: date.mondayDay
    case .monthly: date.monthIndex
    case .yearly: date.year * LocalDate.monthsPerYear
    }
  }

  fileprivate func period(after period: Int) -> Int? {
    let (stride, strideOverflow) =
      switch frequency {
      case .daily, .monthly: (step, false)
      case .weekly: step.multipliedReportingOverflow(by: LocalDate.daysPerWeek)
      case .yearly: step.multipliedReportingOverflow(by: LocalDate.monthsPerYear)
      }
    let (next, overflow) = period.addingReportingOverflow(stride)
    guard !strideOverflow, !overflow else { return nil }
    switch frequency {
    case .daily, .weekly: return next <= LocalDate.latest.daysSinceEpoch ? next : nil
    case .monthly, .yearly: return next <= LocalDate.latest.monthIndex ? next : nil
    }
  }

  fileprivate func dates(in period: Int) -> [LocalDate] {
    switch frequency {
    case .daily:
      return LocalDate(daysSinceEpoch: period).map { [$0] } ?? []
    case .weekly(let weekdays):
      return weekdays.map(\.rawValue).sorted().compactMap { LocalDate(daysSinceEpoch: period + $0 - 1) }
    case .monthly(.dayOfMonth(let day)):
      return LocalDate.clampedToMonthEnd(monthIndex: period, day: day).map { [$0] } ?? []
    case .monthly(.nthWeekday(let weekday, let ordinal)):
      let year = LocalDate.floorDivide(period, LocalDate.monthsPerYear)
      let month = LocalDate.floorModulo(period, LocalDate.monthsPerYear) + 1
      return LocalDate.nthWeekday(weekday, ordinal, year: year, month: month).map { [$0] } ?? []
    case .yearly:
      return LocalDate.clampedToMonthEnd(monthIndex: period + startDate.month - 1, day: startDate.day).map { [$0] } ?? []
    }
  }
}

private struct RawOccurrences: IteratorProtocol {
  let rule: RecurrenceRule
  let anchorDate: LocalDate
  var period: Int?
  var index: Int?
  var pending: ArraySlice<LocalDate> = []
  var isAnchorPeriod = true

  init(rule: RecurrenceRule, anchor: RecurrenceOccurrence) {
    self.rule = rule
    anchorDate = anchor.date
    period = rule.period(of: anchor.date)
    index = anchor.index
  }

  mutating func next() -> RecurrenceOccurrence? {
    while true {
      guard let current = index else { return nil }
      if let date = pending.popFirst() {
        let (following, overflow) = current.addingReportingOverflow(1)
        index = overflow ? nil : following
        return RecurrenceOccurrence(date: date, index: current)
      }
      guard let start = period else { return nil }
      pending = rule.dates(in: start).filter { $0 >= rule.startDate && (!isAnchorPeriod || $0 >= anchorDate) }[...]
      isAnchorPeriod = false
      period = rule.period(after: start)
    }
  }
}
