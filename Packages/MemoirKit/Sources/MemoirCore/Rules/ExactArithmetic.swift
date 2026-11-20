public struct Thousandths: Sendable, Hashable, Comparable, Encodable {
  public let thousandths: Int

  public init(_ thousandths: Int) {
    self.thousandths = thousandths
  }

  public var fraction: Fraction { Fraction(reducing: Int128(thousandths), 1000) }

  public static func < (lhs: Thousandths, rhs: Thousandths) -> Bool {
    lhs.thousandths < rhs.thousandths
  }
}

public struct Tenths: Sendable, Hashable, Comparable, Encodable {
  public let tenths: Int

  public init(_ tenths: Int) {
    self.tenths = tenths
  }

  public var fraction: Fraction { Fraction(reducing: Int128(tenths), 10) }

  public static func < (lhs: Tenths, rhs: Tenths) -> Bool {
    lhs.tenths < rhs.tenths
  }
}

public struct Halves: Sendable, Hashable, Comparable, Encodable {
  public static let zero = Halves(0)

  public let halves: Int

  public init(_ halves: Int) {
    self.halves = halves
  }

  public var fraction: Fraction { Fraction(reducing: Int128(halves), 2) }

  public static func < (lhs: Halves, rhs: Halves) -> Bool {
    lhs.halves < rhs.halves
  }

  public static func median(of values: [Int]) -> Halves {
    guard !values.isEmpty else { return .zero }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if !sorted.count.isMultiple(of: 2) { return Halves(Int(clamping: Int128(sorted[middle]) * 2)) }
    return Halves(Int(clamping: Int128(sorted[middle - 1]) + Int128(sorted[middle])))
  }

  public static func trailingMedian(of values: [Int], windowDays: Int) -> Halves {
    median(of: Array(values.prefix(max(0, windowDays))))
  }
}

public struct Fraction: Sendable, Hashable, Comparable, CustomStringConvertible {
  public static let zero = Fraction(0)

  public let numerator: Int
  public let denominator: Int

  public init(_ integer: Int) {
    numerator = integer
    denominator = 1
  }

  public init?(numerator: Int, denominator: Int) {
    guard denominator != 0 else { return nil }
    self.init(reducing: Int128(numerator), Int128(denominator))
  }

  init(reducing numerator: Int128, _ denominator: Int128) {
    let sign: Int128 = denominator < 0 ? -1 : 1
    let divisor = Self.greatestCommonDivisor(numerator, denominator)
    self.numerator = Int(clamping: sign * numerator / divisor)
    self.denominator = Int(clamping: sign * denominator / divisor)
  }

  public var floor: Int { Int(clamping: Exact.floorDivide(Int128(numerator), Int128(denominator))) }
  public var ceiling: Int { Int(clamping: -Exact.floorDivide(-Int128(numerator), Int128(denominator))) }
  public var roundedHalfUp: Int { Int(clamping: Exact.roundHalfUp(Int128(numerator), Int128(denominator))) }

  public var description: String { denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)" }

  public static func < (lhs: Fraction, rhs: Fraction) -> Bool {
    Int128(lhs.numerator) * Int128(rhs.denominator) < Int128(rhs.numerator) * Int128(lhs.denominator)
  }

  public static func * (lhs: Fraction, rhs: Fraction) -> Fraction {
    Fraction(reducing: Int128(lhs.numerator) * Int128(rhs.numerator), Int128(lhs.denominator) * Int128(rhs.denominator))
  }

  public static func / (lhs: Fraction, rhs: Fraction) -> Fraction? {
    guard rhs.numerator != 0 else { return nil }
    return Fraction(reducing: Int128(lhs.numerator) * Int128(rhs.denominator), Int128(lhs.denominator) * Int128(rhs.numerator))
  }

  private static func greatestCommonDivisor(_ left: Int128, _ right: Int128) -> Int128 {
    var (a, b) = (left.magnitude, right.magnitude)
    while b != 0 { (a, b) = (b, a % b) }
    return a == 0 ? 1 : Int128(a)
  }
}

enum Exact {
  static func floorDivide(_ numerator: Int128, _ denominator: Int128) -> Int128 {
    let quotient = numerator / denominator
    return numerator % denominator != 0 && (numerator < 0) != (denominator < 0) ? quotient - 1 : quotient
  }

  static func roundHalfUp(_ numerator: Int128, _ denominator: Int128) -> Int128 {
    denominator < 0 ? roundHalfUp(-numerator, -denominator) : floorDivide(2 * numerator + denominator, 2 * denominator)
  }

  static func sum(_ values: some Sequence<Int>) -> Int {
    Int(clamping: values.reduce(Int128(0)) { $0 + Int128($1) })
  }

  static func adding(_ left: Int, _ right: Int) -> Int {
    Int(clamping: Int128(left) + Int128(right))
  }

  static func subtracting(_ left: Int, _ right: Int) -> Int {
    Int(clamping: Int128(left) - Int128(right))
  }
}
