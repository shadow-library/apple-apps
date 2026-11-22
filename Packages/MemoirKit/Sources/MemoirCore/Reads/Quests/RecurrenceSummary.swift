/// A recurrence as a sentence describes it, as data: `features/quests/quest-presenters.ts:100-140`. An interval below 1 reads as 1, as replay reads it.
public enum RecurrenceSummary: Sendable, Hashable {
  case daily(interval: Int)
  case weekly(interval: Int, days: WeekdaySpan)
  case monthlyOnDay(interval: Int, day: Int)
  case monthlyOnWeekday(interval: Int, weekday: LocalDate.Weekday, ordinal: WeekdayOrdinal)
  case yearly(interval: Int, month: Int, day: Int)

  public init(_ rule: RecurrenceRule) {
    let interval = max(1, rule.interval)
    switch rule.frequency {
    case .daily: self = .daily(interval: interval)
    case .weekly(let weekdays): self = .weekly(interval: interval, days: WeekdaySpan(weekdays))
    case .monthly(.dayOfMonth(let day)): self = .monthlyOnDay(interval: interval, day: day)
    case .monthly(.nthWeekday(let weekday, let ordinal)): self = .monthlyOnWeekday(interval: interval, weekday: weekday, ordinal: ordinal)
    case .yearly: self = .yearly(interval: interval, month: rule.startDate.month, day: rule.startDate.day)
    }
  }
}

/// `weekdaySpan` (`quest-presenters.ts:100-118`): every day, or the chosen days Monday first, where three or more in a row read as a range.
public enum WeekdaySpan: Sendable, Hashable {
  public static let rangeMinimum = 3

  case everyDay
  case days([WeekdayRun])

  public init(_ weekdays: Set<LocalDate.Weekday>) {
    guard weekdays.count < LocalDate.Weekday.allCases.count else {
      self = .everyDay
      return
    }
    var runs = [[LocalDate.Weekday]]()
    for day in LocalDate.Weekday.allCases where weekdays.contains(day) {
      if let previous = runs.last?.last, previous.rawValue + 1 == day.rawValue {
        runs[runs.count - 1].append(day)
      } else {
        runs.append([day])
      }
    }
    self = .days(
      runs.flatMap { run -> [WeekdayRun] in
        guard run.count >= Self.rangeMinimum, let first = run.first, let last = run.last else { return run.map(WeekdayRun.single) }
        return [.range(from: first, through: last)]
      })
  }
}

public enum WeekdayRun: Sendable, Hashable {
  case single(LocalDate.Weekday)
  case range(from: LocalDate.Weekday, through: LocalDate.Weekday)
}

extension RecurrenceRule {
  /// `streakUnit` (`quest-presenters.ts:145-147`).
  public var streakUnit: StreakUnit {
    if case .daily = frequency, interval <= 1 { return .days }
    return .occurrences
  }
}
