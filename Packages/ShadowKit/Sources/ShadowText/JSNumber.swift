public enum JSMath {
  /// Halves round towards +∞ and [-0.5, 0) rounds to -0, where `rounded()` takes halves away from zero.
  public static func round(_ value: Double) -> Double {
    guard value.isFinite, value != 0 else { return value }
    if value > 0, value < 0.5 { return 0 }
    if value < 0, value >= -0.5 { return -0.0 }
    let floor = value.rounded(.down)
    return value - floor >= 0.5 ? floor + 1 : floor
  }
}

public enum JSNumber {
  static let maximumFixedDigits = 20

  /// NaN is 0, fractions truncate and infinities saturate.
  public static func integer(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 0x1p63 { return Int.max }
    if value <= -0x1p63 { return Int.min }
    return Int(value.rounded(.towardZero))
  }

  /// The empty string is 0, and `0x`, `0o` and `0b` literals parse only without a sign.
  public static func from(_ text: String) -> Double {
    let literal = Array(text.jsTrim().utf8)
    guard !literal.isEmpty else { return 0 }
    if literal.count > 2, literal[0] == UInt8(ascii: "0"), let bits = radixBits(literal[1]) { return radixValue(literal[2...], bitsPerDigit: bits) }
    let negative = literal[0] == UInt8(ascii: "-")
    let unsigned = literal[0] == UInt8(ascii: "-") || literal[0] == UInt8(ascii: "+") ? literal[1...] : literal[...]
    guard let magnitude = unsignedDecimal(unsigned) else { return .nan }
    return negative ? -magnitude : magnitude
  }

  private static func radixBits(_ marker: UInt8) -> Int? {
    switch marker {
    case UInt8(ascii: "x"), UInt8(ascii: "X"): 4
    case UInt8(ascii: "o"), UInt8(ascii: "O"): 3
    case UInt8(ascii: "b"), UInt8(ascii: "B"): 1
    default: nil
    }
  }

  private static func radixValue(_ digits: ArraySlice<UInt8>, bitsPerDigit: Int) -> Double {
    var bits: [Bool] = []
    for byte in digits {
      guard let digit = hexDigit(byte), digit < 1 << bitsPerDigit else { return .nan }
      for shift in stride(from: bitsPerDigit - 1, through: 0, by: -1) { bits.append(digit >> shift & 1 == 1) }
    }
    let significant = bits.drop { !$0 }
    guard significant.count > 64 else { return Double(significant.reduce(UInt64(0)) { $0 << 1 | ($1 ? 1 : 0) }) }
    var top = significant.prefix(64).reduce(UInt64(0)) { $0 << 1 | ($1 ? 1 : 0) }
    if significant.dropFirst(64).contains(true) { top |= 1 }
    return Double(sign: .plus, exponent: significant.count - 64, significand: Double(top))
  }

  private static func hexDigit(_ byte: UInt8) -> Int? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
    default: nil
    }
  }

  private static func unsignedDecimal(_ literal: ArraySlice<UInt8>) -> Double? {
    if literal.elementsEqual("Infinity".utf8) { return .infinity }
    let isDigit = { (byte: UInt8) in (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }
    var rest = literal
    let whole = rest.prefix(while: isDigit)
    rest = rest.dropFirst(whole.count)
    var fraction = ArraySlice<UInt8>()
    if rest.first == UInt8(ascii: ".") {
      rest = rest.dropFirst()
      fraction = rest.prefix(while: isDigit)
      rest = rest.dropFirst(fraction.count)
    }
    guard !whole.isEmpty || !fraction.isEmpty else { return nil }
    var exponent = ArraySlice<UInt8>()
    if rest.first == UInt8(ascii: "e") || rest.first == UInt8(ascii: "E") {
      rest = rest.dropFirst()
      let sign = rest.first == UInt8(ascii: "+") || rest.first == UInt8(ascii: "-") ? rest.prefix(1) : []
      rest = rest.dropFirst(sign.count)
      let digits = rest.prefix(while: isDigit)
      guard !digits.isEmpty else { return nil }
      rest = rest.dropFirst(digits.count)
      exponent = sign + digits
    }
    guard rest.isEmpty else { return nil }
    let canonical = (whole.isEmpty ? "0" : String(decoding: whole, as: UTF8.self)) + "." + (fraction.isEmpty ? "0" : String(decoding: fraction, as: UTF8.self))
    return Double(canonical + (exponent.isEmpty ? "" : "e" + String(decoding: exponent, as: UTF8.self)))
  }
}

extension Double {
  public var jsIsInteger: Bool { isFinite && rounded(.towardZero) == self }

  /// Integers print without a fraction, and an exponent appears only below 1e-6 or from 1e21.
  public var jsString: String {
    if isNaN { return "NaN" }
    if self == 0 { return "0" }
    if isInfinite { return self < 0 ? "-Infinity" : "Infinity" }
    if self < 0 { return "-" + (-self).jsString }
    let (digits, point) = shortestDigits()
    let count = digits.count
    if count <= point, point <= 21 { return digits + String(repeating: "0", count: point - count) }
    if 0 < point, point <= 21 { return String(digits.prefix(point)) + "." + String(digits.dropFirst(point)) }
    if -6 < point, point <= 0 { return "0." + String(repeating: "0", count: -point) + digits }
    let exponent = point - 1
    let mantissa = count == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst())
    return mantissa + "e" + (exponent < 0 ? "-" : "+") + String(Swift.abs(exponent))
  }

  /// Rounds the exact binary value with ties away from zero, where `String(format:)` ties to even; digits outside 0...20 clamp instead of throwing.
  public func jsToFixed(_ requestedDigits: Int) -> String {
    let fractionDigits = Swift.min(Swift.max(requestedDigits, 0), JSNumber.maximumFixedDigits)
    if isNaN { return "NaN" }
    if Swift.abs(self) >= 1e21 { return jsString }
    var digits = Swift.abs(self).fixedDigits(fractionDigits)
    if fractionDigits > 0 {
      if digits.count <= fractionDigits { digits = String(repeating: "0", count: fractionDigits + 1 - digits.count) + digits }
      digits.insert(".", at: digits.index(digits.endIndex, offsetBy: -fractionDigits))
    }
    return self < 0 ? "-" + digits : digits
  }

  private func shortestDigits() -> (digits: String, point: Int) {
    let parts = description.split(separator: "e", maxSplits: 1)
    let mantissa = parts.first.map(String.init) ?? ""
    let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let whole = pieces.first.map(String.init) ?? ""
    let all = whole + (pieces.count > 1 ? String(pieces[1]) : "")
    let leading = all.prefix { $0 == "0" }.count
    let trimmed = all.dropFirst(leading)
    let significant = trimmed.dropLast(trimmed.reversed().prefix { $0 == "0" }.count)
    return (String(significant), whole.count - leading + exponent)
  }

  private func fixedDigits(_ fractionDigits: Int) -> String {
    let exponentBits = Int(exponentBitPattern)
    let significand = UInt128(significandBitPattern) | (exponentBits == 0 ? 0 : 1 << 52)
    let exponent = (exponentBits == 0 ? 1 : exponentBits) - 1075
    if exponent >= 0 { return String(significand << exponent) + String(repeating: "0", count: fractionDigits) }
    let shift = -exponent
    guard shift <= 120 else { return "0" }
    var scale: UInt128 = 1
    for _ in 0..<fractionDigits { scale *= 10 }
    return String((2 * significand * scale + (1 << shift)) >> (shift + 1))
  }
}
