import Foundation
import MemoirCore

/// Dates, times, money and numbers in the owner's locale. A `LocalDate` or a minute has no zone, so each is placed at UTC and formatted there; money is
/// exact from minor units with the currency's ISO 4217 exponent.
nonisolated enum ReflectFormat {
  private static let utc = TimeZone(identifier: "UTC") ?? .gmt
  private static let posix = Locale(identifier: "en_US_POSIX")

  /// "Monday, 2 March" (`formatDayName`).
  static func dayName(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).weekday(.wide).day().month(.wide))
  }

  static func shortDate(_ date: LocalDate) -> String {
    midnight(of: date).formatted(Date.FormatStyle(timeZone: utc).day().month(.abbreviated).year())
  }

  /// "9–15 November" (`formatRange`), with the years only when they differ.
  static func range(_ span: DateSpan) -> String {
    let style = Date.IntervalFormatStyle(timeZone: utc).day().month(.wide)
    let range = midnight(of: span.start)..<midnight(of: span.end)
    return span.start.year == span.end.year ? range.formatted(style) : range.formatted(style.year())
  }

  static func weekday(_ weekday: LocalDate.Weekday, wide: Bool) -> String {
    let symbols = wide ? Calendar.current.standaloneWeekdaySymbols : Calendar.current.shortStandaloneWeekdaySymbols
    return symbols[weekday.rawValue % 7]
  }

  /// A month's short name, with a two-digit year where the reference adds one (`monthLabel`).
  static func month(year: Int, month: Int, withYear: Bool) -> String {
    guard let first = LocalDate(year: year, month: month, day: 1) else { return "\(year)-\(month)" }
    let style = Date.FormatStyle(timeZone: utc).month(.abbreviated)
    return midnight(of: first).formatted(withYear ? style.year(.twoDigits) : style)
  }

  static func longMonth(year: Int, month: Int) -> String {
    guard let first = LocalDate(year: year, month: month, day: 1) else { return "\(year)-\(month)" }
    return midnight(of: first).formatted(Date.FormatStyle(timeZone: utc).month(.wide).year())
  }

  static func time(millis: Int64, in zone: TimeZone) -> String {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
  }

  static func money(_ minor: Int64, _ currency: CurrencyCode) -> String {
    let exponent = ISO4217.exponents[currency.code] ?? 2
    let amount = Decimal(sign: minor < 0 ? .minus : .plus, exponent: -exponent, significand: Decimal(minor.magnitude))
    return amount.formatted(.currency(code: currency.code).precision(.fractionLength(exponent)))
  }

  static func count(_ value: Int) -> String {
    value.formatted(.number)
  }

  static func compact(_ value: Int) -> String {
    value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
  }

  static func percent(_ value: Int) -> String {
    (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
  }

  /// A stored decimal in the locale's digits, with as many places as it was stored with.
  static func decimal(_ value: DecimalText) -> String {
    guard let number = Decimal(string: value.text, locale: posix) else { return value.text }
    return number.formatted(.number.precision(.fractionLength(0...6)))
  }

  static func decimal(_ value: Fraction, places: Int = 1) -> String {
    (Double(value.numerator) / Double(value.denominator)).formatted(.number.precision(.fractionLength(0...places)))
  }

  static func isZero(_ value: DecimalText) -> Bool {
    value.text == "0"
  }

  static func isNegative(_ value: DecimalText) -> Bool {
    value.text.hasPrefix("-")
  }

  static func magnitude(_ value: DecimalText) -> DecimalText {
    isNegative(value) ? DecimalText(String(value.text.dropFirst())) ?? value : value
  }

  static func double(_ value: DecimalText) -> Double? {
    Double(value.text)
  }

  private static func midnight(of date: LocalDate) -> Date {
    Date(timeIntervalSince1970: TimeInterval(date.daysSinceEpoch) * 86_400)
  }
}
