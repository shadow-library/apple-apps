import Foundation
import MemoirCore

/// Money shown exactly: a minor-unit amount becomes a `Decimal` with the currency's ISO 4217 exponent, which the locale's currency format prints with
/// exactly that many decimal places, so nothing passes through a binary float or rounds.
nonisolated enum MoneyText {
  static func exponent(of currency: CurrencyCode) -> Int? {
    ISO4217.exponents[currency.code]
  }

  static func decimal(_ minor: Int64, exponent: Int) -> Decimal {
    Decimal(sign: minor < 0 ? .minus : .plus, exponent: -exponent, significand: Decimal(minor.magnitude))
  }

  static func formatted(_ minor: Int64, _ currency: CurrencyCode, locale: Locale) -> String {
    guard let exponent = exponent(of: currency) else { return "\(minor) \(currency.code)" }
    return decimal(minor, exponent: exponent).formatted(.currency(code: currency.code).locale(locale).precision(.fractionLength(exponent)))
  }

  static func formatted(_ amount: MoneyAmount, locale: Locale) -> String {
    formatted(amount.amountMinor, amount.currency, locale: locale)
  }

  /// A saved amount as the amount field shows it: digits and the locale's decimal separator, no grouping, so `AmountInput` reads it back exactly.
  static func editable(_ minor: Int64, _ currency: CurrencyCode, format: AmountFormat) -> String {
    let exponent = exponent(of: currency) ?? 0
    let digits = String(minor.magnitude)
    guard exponent > 0 else { return digits }
    let padded = String(repeating: "0", count: max(0, exponent + 1 - digits.count)) + digits
    return "\(padded.dropLast(exponent))\(format.decimalSeparator)\(padded.suffix(exponent))"
  }

  /// The amount the empty-amount hint shows, 18.40 in the currency's places, as memoir-web's "for example 18.40".
  static func example(_ currency: CurrencyCode, format: AmountFormat) -> String {
    let exponent = exponent(of: currency) ?? 2
    guard exponent > 0 else { return "18" }
    return "18\(format.decimalSeparator)40" + String(repeating: "0", count: max(0, exponent - 2))
  }

  /// The currency's name in the owner's language, with its code.
  static func currencyName(_ currency: CurrencyCode, locale: Locale) -> String {
    guard let name = locale.localizedString(forCurrencyCode: currency.code) else { return currency.code }
    return "\(currency.code) · \(name)"
  }

  /// A rate's exact digits with the locale's decimal separator.
  static func rate(_ rate: DecimalText, locale: Locale) -> String {
    guard let value = Decimal(string: rate.text, locale: Locale(identifier: "en_US_POSIX")) else { return rate.text }
    return value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...ExchangeRate.maximumScale)))
  }

  /// A rate as the rate field shows it: its exact digits and the locale's decimal separator, no grouping, so `RateInput` reads it back exactly.
  static func editableRate(_ rate: DecimalText, format: AmountFormat) -> String {
    String(rate.text.map { $0 == "." ? format.decimalSeparator : $0 })
  }

  /// The change against the previous stretch as a whole percentage, halves up, without its sign.
  static func percent(_ fraction: Fraction) -> Int {
    let magnitude = Int128(fraction.numerator.magnitude)
    let denominator = Int128(fraction.denominator)
    return Int(clamping: (magnitude * 200 + denominator) / (denominator * 2))
  }
}

/// Civil dates shown in the owner's locale and calendar. A `LocalDate` is a day, not an instant, so it is formatted at midnight UTC in UTC.
nonisolated enum MoneyDates {
  private static let utc = TimeZone(identifier: "UTC") ?? .gmt

  static func instant(_ day: LocalDate) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day.daysSinceEpoch) * 86_400)
  }

  static func text(_ day: LocalDate, locale: Locale, showsYear: Bool = true) -> String {
    var calendar = locale.calendar
    calendar.timeZone = utc
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: utc).day().month(.abbreviated)
    return instant(day).formatted(showsYear ? style.year() : style)
  }

  /// A month and its year, as a goal's estimate names it.
  static func month(_ day: LocalDate, locale: Locale) -> String {
    var calendar = locale.calendar
    calendar.timeZone = utc
    return instant(day).formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: utc).month(.wide).year())
  }

  /// When a command was issued, at the offset it recorded.
  static func moment(millis: Int64, offsetMinutes: Int, locale: Locale) -> String {
    let zone = TimeZone(secondsFromGMT: offsetMinutes * 60) ?? utc
    var calendar = locale.calendar
    calendar.timeZone = zone
    let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, calendar: calendar, timeZone: zone)
    return Date(timeIntervalSince1970: TimeInterval(millis) / 1000).formatted(style)
  }

  /// The date picker works in the device's zone; noon keeps a day whole across a daylight-saving change.
  static func pickerDate(_ day: LocalDate) -> Date {
    let calendar = gregorian
    return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? instant(day)
  }

  static func localDate(_ date: Date) -> LocalDate? {
    let parts = gregorian.dateComponents([.year, .month, .day], from: date)
    guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
    return LocalDate(year: year, month: month, day: day)
  }

  private static var gregorian: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    return calendar
  }
}
