import Foundation
import MemoirCore

/// Civil dates and minutes of the day in the owner's locale. A `LocalDate` or a minute has no zone, so each is placed at UTC and formatted there.
enum TodayFormat {
  private static let utc = TimeZone(identifier: "UTC") ?? .gmt
  private static let weekdayNameWithinDays = 6

  static func time(minuteOfDay minute: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(minute * 60))
    return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: utc))
  }

  static func time(millis: Int64, in zone: TimeZone) -> String {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
  }

  /// "Monday, 2 March" in the owner's locale (`formatDayName`).
  static func dayName(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).weekday(.wide).day().month(.wide))
  }

  static func shortDate(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).day().month(.abbreviated))
  }

  static func weekday(_ date: LocalDate, wide: Bool) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).weekday(wide ? .wide : .abbreviated))
  }

  /// `relativeDayLabel` (`fixture-provider.ts:143-148`).
  static func relativeDay(_ date: LocalDate, from today: LocalDate) -> String {
    if date == today { return String(localized: "Today", table: "Today") }
    if date == today.adding(days: 1) { return String(localized: "Tomorrow", table: "Today") }
    return weekday(date, wide: false)
  }

  /// `nextDayLabel` (`features/today/index.tsx:30-34`).
  static func nextDay(_ date: LocalDate, from today: LocalDate) -> String {
    if date == today.adding(days: 1) { return String(localized: "Tomorrow", table: "Today") }
    if date.days(since: today) <= weekdayNameWithinDays { return weekday(date, wide: true) }
    let style = Date.FormatStyle(timeZone: utc).day().month(.wide)
    return midnight(of: date).formatted(date.year == today.year ? style : style.year())
  }

  static func duration(minutes: Int) -> String {
    Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
  }

  /// `+0530`-style offset for a zone this device does not know.
  static func offset(minutes: Int) -> String {
    let sign = minutes < 0 ? "-" : "+"
    let magnitude = abs(minutes)
    return String(format: "%@%02d:%02d", sign, magnitude / 60, magnitude % 60)
  }

  private static func midnight(of date: LocalDate) -> Date {
    Date(timeIntervalSince1970: TimeInterval(date.daysSinceEpoch) * 86_400)
  }
}
