import ShadowTestSupport
import Testing

@testable import NovelForgeCore

struct JSNumberTests {
  private let iterations = 300

  @Test func shouldRoundLikeMathRound() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0301) { random in
      let value = random.jsDouble()
      try expectExactlySame(JSMath.round(value), oracle.call("x => Math.round(x)", .number(value)), "\(value)")
    }
  }

  @Test func shouldFormatToFixedLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0302) { random in
      let value = random.jsDouble()
      let digits = random.chance(0.1) ? random.pick(from: [5, 17, 20]) : random.int(in: 0...3)
      try expectExactlySame(value.jsToFixed(digits), oracle.call("(x, d) => x.toFixed(d)", .number(value), .number(Double(digits))), "\(value).toFixed(\(digits))")
    }
  }

  @Test func shouldConvertNumbersToStringsLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0303) { random in
      let value = random.chance(0.5) ? random.jsDouble() : Double(bitPattern: random.next())
      try expectExactlySame(value.jsString, oracle.call("x => String(x)", .number(value)), "\(value)")
      try expectExactlySame(value.jsIsInteger, oracle.call("x => Number.isInteger(x)", .number(value)), "\(value)")
    }
  }

  @Test func shouldParseStringsLikeNumber() throws {
    let oracle = try JSOracle()
    let pieces = [
      "0", "1", "9", "12", "007", ".", "e", "E", "+", "-", "x", "X", "o", "O", "b", "B", "0x", "0X", "0o", "0b", "Infinity", "infinity", "_", "a", "f", "F", "8",
      "1e400", "1e-400", " ", "\u{FEFF}", "\u{A0}", "\n", "\u{85}", "٣", "5.", "NaN", "chapter", "fFfFfFfFfFfFfFfF", String(repeating: "1", count: 25),
    ]
    try forAll(iterations: iterations, seed: 0xD03_0304) { random in
      let text = (0..<random.int(in: 0...4)).map { _ in random.pick(from: pieces) }.joined()
      try expectExactlySame(JSNumber.from(text), oracle.call("s => Number(s)", .string(text)), describe(text))
    }
  }
}

extension SeededGenerator {
  mutating func jsDouble() -> Double {
    let sign: Double = chance(0.5) ? -1 : 1
    switch int(in: 0...7) {
    case 0: return pick(from: [.nan, .infinity, -.infinity, 0, -0.0, 0.49999999999999994, 1e21, 999_999_999_999_999_900_000, 5e-324, .greatestFiniteMagnitude, 0x1p52 + 0.5])
    case 1: return sign * (Double(int(in: 0...40)) + 0.5)
    case 2: return sign * Double(int(in: 0...4000)) / 8
    case 3: return sign * Double(int(in: 0...100_000)) / 1000
    case 4: return sign * Double(int(in: 0...1_000_000)) / 1e7
    case 5: return sign * Double(int(in: 0...Int(Int32.max))) * pick(from: [1e-30, 1e-9, 1e-7, 1e-6, 1, 1e12, 1e15, 1e20, 1e25])
    case 6: return sign * Double(int(in: 0...1000))
    default: return Double(bitPattern: next())
    }
  }
}
