import Foundation
import MemoirCore

/// Civil days and minutes of the day as dates the locale's formats can show. A day is placed at noon, so a daylight-saving change never moves it to another
/// day, and a minute on 1 January 2001, a day with no clock change.
nonisolated enum QuestCalendar {
  static func date(_ day: LocalDate, calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? .distantPast
  }

  static func time(_ minute: Int, calendar: Calendar = .current) -> Date {
    calendar.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60)) ?? .distantPast
  }

  static func minute(of date: Date, calendar: Calendar = .current) -> Int {
    let components = calendar.dateComponents([.hour, .minute], from: date)
    return (components.hour ?? 0) * 60 + (components.minute ?? 0)
  }

  /// `Calendar.weekdaySymbols` count from Sunday; `LocalDate.Weekday` from Monday.
  static func symbolIndex(_ weekday: LocalDate.Weekday) -> Int {
    weekday.rawValue % 7
  }

  /// The week's days in order from the account's first day of the week.
  static func week(from start: LocalDate.Weekday) -> [LocalDate.Weekday] {
    (0..<7).compactMap { LocalDate.Weekday(rawValue: (start.rawValue - 1 + $0) % 7 + 1) }
  }
}
