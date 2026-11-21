/// A positive decimal rate held exactly as `significand × 10^-scale`, read from its decimal text and never through a binary float.
public struct ExchangeRate: Hashable, Sendable, CustomStringConvertible {
  public static let maximumScale = 18
  public static let maximumDigits = 18
  /// apps/memoir-server/src/database/schemas/finance.ts: `fx_rates.rate` is `numeric(18, 8)`, so the reference keeps eight decimal places.
  public static let storedScale = 8

  public let significand: Int64
  public let scale: Int

  public init(_ text: DecimalText) throws(FinanceError) {
    let parts = try Self.digits(of: text)
    let significant = Array(parts.digits.drop { $0 == 0 })
    guard !significant.isEmpty else { throw .rateNotPositive(text) }
    guard significant.count <= Self.maximumDigits, parts.scale <= Self.maximumScale else { throw .rateOutOfRange(text) }
    significand = significant.reduce(Int64(0)) { $0 * 10 + Int64($1) }
    scale = parts.scale
  }

  /// Rounds half up to `scale` decimal places first, so a provider's long rate is kept the way the reference stores it.
  public static func rounded(_ text: DecimalText, toScale scale: Int = storedScale) throws(FinanceError) -> ExchangeRate {
    guard (0...maximumScale).contains(scale) else { throw .rateOutOfRange(text) }
    let parts = try digits(of: text)
    guard parts.scale > scale else { return try ExchangeRate(text) }
    var kept = Array(parts.digits.dropLast(parts.scale - scale))
    if parts.digits[kept.count] >= 5 { kept = incremented(kept) }
    guard let rounded = DecimalText(canonical(kept, scale: scale)) else { throw .rateOutOfRange(text) }
    return try ExchangeRate(rounded)
  }

  public var text: DecimalText {
    guard let text = DecimalText(Self.canonical(String(significand).utf8.map { $0 - UInt8(ascii: "0") }, scale: scale)) else {
      preconditionFailure("a positive significand with at most \(Self.maximumScale) decimal places is a canonical decimal")
    }
    return text
  }

  public var description: String { text.text }

  private static func digits(of text: DecimalText) throws(FinanceError) -> (digits: [UInt8], scale: Int) {
    let bytes = Array(text.text.utf8)
    guard bytes.first != UInt8(ascii: "-") else { throw .rateNotPositive(text) }
    let parts = bytes.split(separator: UInt8(ascii: "."), maxSplits: 1, omittingEmptySubsequences: false)
    let fraction = parts.count == 2 ? Array(parts[1]) : []
    return ((Array(parts[0]) + fraction).map { $0 - UInt8(ascii: "0") }, fraction.count)
  }

  private static func incremented(_ digits: [UInt8]) -> [UInt8] {
    var result = digits
    var index = result.count - 1
    while index >= 0 {
      guard result[index] == 9 else {
        result[index] += 1
        return result
      }
      result[index] = 0
      index -= 1
    }
    return [1] + result
  }

  private static func canonical(_ digits: [UInt8], scale: Int) -> String {
    let padded = Array(repeating: UInt8(0), count: max(0, scale + 1 - digits.count)) + digits
    let whole = padded.dropLast(scale).drop { $0 == 0 }
    var fraction = Array(padded.suffix(scale))
    while fraction.last == 0 { fraction.removeLast() }
    let wholeText = whole.isEmpty ? "0" : String(decoding: whole.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
    guard !fraction.isEmpty else { return wholeText }
    return wholeText + "." + String(decoding: fraction.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
  }
}

/// Converts into the home currency with the ISO 4217 exponents applied:
/// `home = roundHalfUp(amountMinor × rate × 10^(eHome − eSource))`, halves toward positive infinity as JavaScript's `Math.round` rounds.
/// The reference multiplies minor units by the rate without the exponents, so it is wrong whenever the two exponents differ (JPY to EUR).
public enum HomeConversion {
  public static func convert(_ amount: MoneyAmount, to home: CurrencyCode, at rate: ExchangeRate) throws(FinanceError) -> MoneyAmount {
    let sourceExponent = try ISO4217.exponent(of: amount.currency)
    let homeExponent = try ISO4217.exponent(of: home)
    guard amount.currency != home else { return amount }
    let product = Int128(amount.amountMinor) * Int128(rate.significand)
    let shift = rate.scale + sourceExponent - homeExponent
    let converted: Int128
    if shift >= 0 {
      converted = roundHalfUp(product, power(of: shift))
    } else {
      let (scaled, overflow) = product.multipliedReportingOverflow(by: power(of: -shift))
      guard !overflow else { throw .overflow }
      converted = scaled
    }
    guard let minor = Int64(exactly: converted) else { throw .overflow }
    return MoneyAmount(amountMinor: minor, currency: home)
  }

  static func roundHalfUp(_ numerator: Int128, _ denominator: Int128) -> Int128 {
    var quotient = numerator / denominator
    var remainder = numerator % denominator
    if remainder < 0 {
      quotient -= 1
      remainder += denominator
    }
    return 2 * remainder >= denominator ? quotient + 1 : quotient
  }

  private static func power(of exponent: Int) -> Int128 {
    (0..<exponent).reduce(Int128(1)) { value, _ in value * 10 }
  }
}
