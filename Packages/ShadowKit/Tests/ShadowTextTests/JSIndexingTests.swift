import ShadowTestSupport
import Testing

@testable import ShadowText

struct JSIndexingTests {
  private let iterations = 300

  @Test func shouldMeasureLengthInCodeUnits() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0001) { random in
      let text = random.jsText()
      try expectSame(text.jsLength, oracle.call("s => s.length", .string(text)), describe(text))
    }
  }

  @Test func shouldReadCharAtAndCharCodeAtLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0002) { random in
      let text = random.jsText()
      let position = random.jsPosition(around: text.jsLength)
      let index = JSNumber.integer(position)
      try expectSame(text.jsCharAt(index), oracle.call("(s, i) => s.charAt(i)", .string(text), .number(position)), "\(describe(text)) at \(position)")
      try expectExactlySame(text.jsCharCodeAt(index), oracle.call("(s, i) => s.charCodeAt(i)", .string(text), .number(position)), "\(describe(text)) at \(position)")
    }
  }

  @Test func shouldSliceLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0003) { random in
      let text = random.jsText()
      let start = random.jsPosition(around: text.jsLength)
      let end = random.chance(0.2) ? nil : random.jsPosition(around: text.jsLength)
      let swift = text.jsSlice(JSNumber.integer(start), end.map(JSNumber.integer))
      let javaScript = try oracle.call("(s, a, b) => s.slice(a, b)", .string(text), .number(start), end.map(JSOracleArgument.number) ?? .undefined)
      try expectSame(swift, javaScript, "\(describe(text)).slice(\(start), \(String(describing: end)))")
      try expectExactlySame(JSOracleValue.string(text.jsSliceCodeUnits(JSNumber.integer(start), end.map(JSNumber.integer))), javaScript, "code units of \(describe(text))")
    }
  }

  @Test func shouldFindIndexOfLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0005) { random in
      let text = random.jsText()
      let needle = random.jsNeedle(in: text)
      let position = random.jsPosition(around: text.jsLength)
      let javaScript = try oracle.call("(s, t, i) => s.indexOf(t, i)", .string(text), .string(needle), .number(position))
      try expectExactlySame(text.jsIndexOf(needle, JSNumber.integer(position)), javaScript, "\(describe(text)).indexOf(\(describe(needle)), \(position))")
    }
  }

  @Test func shouldTestIncludesStartsWithAndEndsWithLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0007) { random in
      let text = random.jsText()
      let needle = random.jsNeedle(in: text)
      let position = random.jsPosition(around: text.jsLength)
      let end: Double? = random.chance(0.4) ? nil : random.jsPosition(around: text.jsLength)
      let label = "\(describe(text)) with \(describe(needle)) at \(position) / \(String(describing: end))"
      let includes = try oracle.call("(s, t, i) => s.includes(t, i)", .string(text), .string(needle), .number(position))
      try expectExactlySame(text.jsIncludes(needle, JSNumber.integer(position)), includes, label)
      let startsWith = try oracle.call("(s, t, i) => s.startsWith(t, i)", .string(text), .string(needle), .number(position))
      try expectExactlySame(text.jsStartsWith(needle, JSNumber.integer(position)), startsWith, label)
      let endsWith = try oracle.call("(s, t, i) => s.endsWith(t, i)", .string(text), .string(needle), end.map(JSOracleArgument.number) ?? .undefined)
      try expectExactlySame(text.jsEndsWith(needle, end.map(JSNumber.integer)), endsWith, label)
    }
  }

  @Test func shouldCompareStrictlyLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0008) { random in
      let left = random.jsText(maxPieces: 3)
      let right = random.chance(0.4) ? left.jsNormalize(random.pick(from: [JSNormalizationForm.nfc, .nfd])) : random.jsText(maxPieces: 3)
      try expectExactlySame(left.jsEquals(right), oracle.call("(a, b) => a === b", .string(left), .string(right)), "\(describe(left)) === \(describe(right))")
    }
  }

  @Test func shouldIterateCodePointsLikeJavaScriptSpread() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0009) { random in
      let text = random.jsText()
      try expectExactlySame(text.jsCodePoints, oracle.call("s => [...s]", .string(text)), describe(text))
    }
  }

  @Test func shouldRoundTripUTF16OffsetsThroughStringIndices() throws {
    try forAll(iterations: iterations, seed: 0xD03_000A) { random in
      let text = random.jsText()
      let units = text.jsCodeUnits
      for offset in 0...units.count {
        let insidePair = offset > 0 && offset < units.count && UTF16.isLeadSurrogate(units[offset - 1])
        let down = text.jsUTF16Offset(of: text.jsIndex(utf16Offset: offset, rounding: .down))
        let up = text.jsUTF16Offset(of: text.jsIndex(utf16Offset: offset, rounding: .up))
        guard down == (insidePair ? offset - 1 : offset), up == (insidePair ? offset + 1 : offset) else {
          throw Mismatch(description: "offset \(offset) of \(describe(text)) rounded to \(down) and \(up)")
        }
      }
    }
  }
}
