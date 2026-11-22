/// A decimal read exactly as `significand × 10^-scale`. Values come from synced records, so every operation reports overflow: a value past 30
/// significant digits or 18 places is not read, and an operation that would leave `Int128` gives `nil`, never a trap or a clamp.
struct ExactDecimal: Sendable, Hashable, Comparable {
  static let maximumScale = 18
  static let maximumDigits = 30
  static let zero = ExactDecimal(significand: 0, scale: 0)

  let significand: Int128
  let scale: Int

  init(significand: Int128, scale: Int) {
    self.significand = significand
    self.scale = scale
  }

  init?(_ text: DecimalText) {
    let bytes = Array(text.text.utf8)
    let negative = bytes.first == UInt8(ascii: "-")
    let unsigned = negative ? bytes.dropFirst() : bytes[...]
    let parts = unsigned.split(separator: UInt8(ascii: "."), maxSplits: 1, omittingEmptySubsequences: false)
    let fraction = parts.count == 2 ? parts[1] : []
    let digits = Array(parts[0]) + Array(fraction)
    guard fraction.count <= Self.maximumScale, digits.count <= Self.maximumDigits else { return nil }
    let magnitude = digits.reduce(Int128(0)) { $0 * 10 + Int128($1 - UInt8(ascii: "0")) }
    self.init(significand: negative ? -magnitude : magnitude, scale: fraction.count)
  }

  init(_ integer: Int) {
    self.init(significand: Int128(integer), scale: 0)
  }

  /// `10^exponent` for 0 to 38, the powers `Int128` holds.
  static func power(_ exponent: Int) -> Int128? {
    guard (0...38).contains(exponent) else { return nil }
    return (0..<exponent).reduce(Int128(1)) { value, _ in value * 10 }
  }

  func rescaled(to target: Int) -> Int128? {
    guard target >= scale, let factor = Self.power(target - scale) else { return nil }
    return Exact.multiplied(significand, factor)
  }

  func adding(_ other: ExactDecimal) -> ExactDecimal? {
    let scale = max(scale, other.scale)
    guard let left = rescaled(to: scale), let right = other.rescaled(to: scale) else { return nil }
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? nil : ExactDecimal(significand: sum, scale: scale)
  }

  func subtracting(_ other: ExactDecimal) -> ExactDecimal? {
    adding(ExactDecimal(significand: -other.significand, scale: other.scale))
  }

  /// The whole part and the fraction at 18 places, both truncated toward zero, so they share the value's sign and order it without rescaling.
  private var parts: (whole: Int128, fraction: Int128) {
    let unit = Self.power(scale) ?? 1
    let fractionFactor = Self.power(Self.maximumScale - scale) ?? 1
    return (significand / unit, significand % unit * fractionFactor)
  }

  static func < (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
    lhs.parts < rhs.parts
  }

  static func == (lhs: ExactDecimal, rhs: ExactDecimal) -> Bool {
    lhs.parts == rhs.parts
  }

  func hash(into hasher: inout Hasher) {
    let parts = parts
    hasher.combine(parts.whole)
    hasher.combine(parts.fraction)
  }

  /// Its canonical text, or `nil` past `DecimalText`'s length.
  var text: DecimalText? {
    let negative = significand < 0
    var digits = String(significand.magnitude)
    if digits.count <= scale { digits = String(repeating: "0", count: scale + 1 - digits.count) + digits }
    var whole = String(digits.dropLast(scale))
    var fraction = String(digits.suffix(scale))
    while fraction.hasSuffix("0") { fraction.removeLast() }
    if whole.isEmpty { whole = "0" }
    let unsigned = fraction.isEmpty ? whole : "\(whole).\(fraction)"
    return DecimalText(negative && unsigned != "0" ? "-" + unsigned : unsigned)
  }

  /// `numerator / denominator` rounded to `places` decimal places, halves toward positive infinity as JavaScript's `Math.round`; `nil` on overflow or a
  /// zero denominator.
  static func rounding(_ numerator: Int128, over denominator: Int128, places: Int) -> ExactDecimal? {
    guard denominator != 0, let factor = power(places), var numerator = Exact.multiplied(numerator, factor) else { return nil }
    var denominator = denominator
    if denominator < 0 {
      guard let flipped = Exact.negated(numerator), let positive = Exact.negated(denominator) else { return nil }
      numerator = flipped
      denominator = positive
    }
    var quotient = numerator / denominator
    var remainder = numerator % denominator
    if remainder < 0 {
      quotient -= 1
      remainder += denominator
    }
    return ExactDecimal(significand: remainder >= denominator - remainder ? quotient + 1 : quotient, scale: places)
  }
}

extension Exact {
  static func multiplied(_ left: Int128, _ right: Int128) -> Int128? {
    let (product, overflow) = left.multipliedReportingOverflow(by: right)
    return overflow ? nil : product
  }

  static func negated(_ value: Int128) -> Int128? {
    value == .min ? nil : -value
  }
}

extension Fraction {
  /// `numerator / denominator` reduced, or `nil` when the reduced terms do not fit in `Int` (where `Fraction(reducing:)` would clamp).
  static func exactly(_ numerator: Int128, _ denominator: Int128) -> Fraction? {
    guard denominator != 0 else { return nil }
    var (a, b) = (numerator.magnitude, denominator.magnitude)
    while b != 0 { (a, b) = (b, a % b) }
    let divisor = Int128(a == 0 ? 1 : a)
    guard let top = Int(exactly: numerator / divisor), let bottom = Int(exactly: denominator / divisor) else { return nil }
    return Fraction(numerator: top, denominator: bottom)
  }

  /// The value rounded to `places` decimal places, halves toward positive infinity; `nil` only past `DecimalText`'s length.
  public func rounded(toPlaces places: Int) -> DecimalText? {
    ExactDecimal.rounding(Int128(numerator), over: Int128(denominator), places: max(0, min(places, ExactDecimal.maximumScale)))?.text
  }

  /// The value as a whole percentage, halves toward positive infinity.
  public var percent: Int { Int(clamping: Exact.roundHalfUp(Int128(numerator) * 100, Int128(denominator))) }
}

extension DecimalText {
  /// The exact mean of the values; `nil` for none, or when a value cannot be read exactly or the sum or the mean's terms overflow.
  static func mean(_ values: [DecimalText]) -> Fraction? {
    guard !values.isEmpty else { return nil }
    var sum = ExactDecimal.zero
    for value in values {
      guard let exact = ExactDecimal(value), let next = sum.adding(exact) else { return nil }
      sum = next
    }
    guard let unit = ExactDecimal.power(sum.scale), let denominator = Exact.multiplied(unit, Int128(values.count)) else { return nil }
    return Fraction.exactly(sum.significand, denominator)
  }

  /// `self − other`, exactly; `nil` when either cannot be read exactly or the difference overflows.
  func minus(_ other: DecimalText) -> DecimalText? {
    guard let left = ExactDecimal(self), let right = ExactDecimal(other) else { return nil }
    return left.subtracting(right)?.text
  }
}
