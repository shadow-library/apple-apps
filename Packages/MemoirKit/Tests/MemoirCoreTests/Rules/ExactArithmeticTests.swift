import MemoirCore
import Testing

@Suite("Exact arithmetic", TestTimeLimit.quick)
struct ExactArithmeticTests {
  private static func fraction(_ numerator: Int, _ denominator: Int) throws -> Fraction {
    try #require(Fraction(numerator: numerator, denominator: denominator))
  }

  @Test("should reduce and keep the denominator positive")
  func reduces() throws {
    let fraction = try Self.fraction(6, -4)
    #expect(fraction.numerator == -3 && fraction.denominator == 2)
    #expect(try Self.fraction(0, -7) == .zero)
    #expect(Fraction(numerator: 1, denominator: 0) == nil)
  }

  @Test("should round halves toward positive infinity as Math.round does")
  func roundsHalfUp() throws {
    let cases: [(Int, Int, Int)] = [(5, 2, 3), (-5, 2, -2), (-3, 2, -1), (7, 2, 4), (-7, 2, -3), (23, 2, 12), (-1, 3, 0), (-2, 3, -1), (11, 10, 1)]
    for (numerator, denominator, rounded) in cases { #expect(try Self.fraction(numerator, denominator).roundedHalfUp == rounded) }
  }

  @Test("should floor and ceil toward the correct side of zero")
  func floorsAndCeils() throws {
    #expect(try Self.fraction(-7, 2).floor == -4)
    #expect(try Self.fraction(-7, 2).ceiling == -3)
    #expect(try Self.fraction(7, 2).floor == 3)
    #expect(try Self.fraction(7, 2).ceiling == 4)
    #expect(try Self.fraction(-6, 3).floor == -2)
  }

  @Test("should compare by cross-multiplication without overflow")
  func compares() throws {
    #expect(try Self.fraction(21, 70) == Thousandths(300).fraction)
    #expect(!(try Self.fraction(21, 70) < Thousandths(300).fraction))
    #expect(try Self.fraction(.max, .max - 1) > Fraction(1))
    #expect(try Self.fraction(.min + 1, 3) < Fraction(.min / 4))
  }

  @Test("should take medians as exact halves, saturating rather than trapping at the integer edge")
  func medians() {
    #expect(Halves.median(of: []) == .zero)
    #expect(Halves.median(of: [4, 1, 3, 2]) == Halves(5))
    #expect(Halves.median(of: [-4, -1]) == Halves(-5))
    #expect(Halves.median(of: [.max, .max]) == Halves(.max))
    #expect(Halves.trailingMedian(of: [5, 5], windowDays: -1) == .zero)
  }
}
