import Foundation
import MemoirCore

/// The currencies memoir-web offers (`CURRENCIES`, `lib/data/finance.types.ts:16-36`), with their names in the owner's locale.
nonisolated enum SettingsCurrencies {
  static let supported: [CurrencyCode] = [
    "EUR", "USD", "GBP", "NOK", "SEK", "DKK", "CHF", "JPY", "INR", "AED", "AUD", "CAD", "NZD", "SGD", "HKD", "PLN", "CZK", "ZAR", "BRL",
  ].compactMap(CurrencyCode.init)

  /// The locale's own currency when memoir-web offers it, else the reference's first, the euro.
  static func standard(for locale: Locale) -> CurrencyCode {
    if let code = locale.currency?.identifier, let currency = CurrencyCode(code), supported.contains(currency) { return currency }
    return supported[0]
  }

  /// A currency's name with its code: "Euro (EUR)".
  static func label(_ currency: CurrencyCode, locale: Locale = .current) -> String {
    guard let name = locale.localizedString(forCurrencyCode: currency.code) else { return currency.code }
    return String(localized: "\(name) (\(currency.code))", table: "Settings")
  }

  /// The home currency first, then the others in the order they are offered, then any other the record holds.
  static func ordered(_ currencies: Set<CurrencyCode>, home: CurrencyCode) -> [CurrencyCode] {
    let others = currencies.subtracting([home])
    let offered = supported.filter(others.contains)
    let rest = others.subtracting(offered).sorted { $0.code < $1.code }
    return [home] + offered + rest
  }

  /// The budget as the field shows it: the exact minor units with the currency's places and the locale's decimal separator, ungrouped.
  static func text(minor: Int64, currency: CurrencyCode, format: AmountFormat) -> String {
    guard let exponent = try? ISO4217.exponent(of: currency), exponent > 0 else { return String(minor) }
    let digits = String(minor.magnitude)
    let padded = String(repeating: "0", count: max(0, exponent + 1 - digits.count)) + digits
    let split = padded.index(padded.endIndex, offsetBy: -exponent)
    return (minor < 0 ? "-" : "") + padded[..<split] + String(format.decimalSeparator) + padded[split...]
  }
}
