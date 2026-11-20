import ShadowTestSupport
import Testing

@testable import ShadowText

struct LoneSurrogateRuleTests {
  @Test func shouldDropTheDanglingHalfOfACutSurrogatePair() {
    #expect(JSText.string(fromCodeUnits: [0xD83D, 0x61]) == "a")
    #expect(JSText.string(fromCodeUnits: [0x61, 0xDE00]) == "a")
    #expect(JSText.string(fromCodeUnits: [0xDE00, 0xD83D]).isEmpty)
    #expect(JSText.string(fromCodeUnits: [0xD83D, 0xDE00]) == "😀")
  }

  @Test func shouldApplyTheRuleWhereJavaScriptWouldReturnALoneSurrogate() {
    #expect("a😀b".jsSlice(0, 2) == "a")
    #expect("a😀b".jsSlice(2) == "b")
    #expect("😀".jsCharAt(0).isEmpty)
    #expect("😀".jsSplit("") == ["", ""])
  }

  @Test func shouldKeepEveryCodeUnitWhenAskedForCodeUnits() {
    #expect("a😀b".jsSliceCodeUnits(0, 2) == [0x61, 0xD83D])
    #expect("😀".jsCharCodeAt(1) == 0xDE00)
    #expect("a😀b".jsLength == 4)
  }

  @Test func shouldDropExactlyTheUnpairedHalvesOfWhatJavaScriptReturns() throws {
    let oracle = try JSOracle()
    var cutPairs = 0
    try forAll(iterations: 300, seed: 0xD03_0401) { random in
      let text = random.jsText()
      let start = random.int(in: -2...(text.jsLength + 2))
      let end = random.int(in: -2...(text.jsLength + 2))
      let sliced = try oracle.call("(s, a, b) => s.slice(a, b)", .string(text), .number(Double(start)), .number(Double(end)))
      let charAt = try oracle.call("(s, i) => s.charAt(i)", .string(text), .number(Double(start)))
      let pieces = try oracle.call("s => s.split('')", .string(text))
      guard case .string(let slicedUnits) = sliced, case .string(let charUnits) = charAt, case .array(let pieceValues) = pieces else {
        throw Mismatch(description: "the oracle returned \(sliced), \(charAt), \(pieces)")
      }
      let pieceUnits = try pieceValues.map { value in
        guard case .string(let units) = value else { throw Mismatch(description: "split returned \(value)") }
        return units
      }
      if pairedUnitsOnly(slicedUnits) != slicedUnits { cutPairs += 1 }
      let expected = [pairedUnitsOnly(slicedUnits), pairedUnitsOnly(charUnits)] + pieceUnits.map(pairedUnitsOnly)
      let actual = [text.jsSlice(start, end), text.jsCharAt(start)] + text.jsSplit("")
      guard actual.map({ Array($0.utf16) }) == expected else {
        throw Mismatch(description: "\(describe(text)) slice(\(start), \(end)): Swift \(actual.map(describe)) but expected \(expected)")
      }
    }
    #expect(cutPairs > 0)
  }

  @Test func shouldDecodeArbitraryCodeUnitsLikeAPlainLoop() throws {
    let alphabet: [UInt16] = [0x61, 0x20, 0xD83D, 0xDE00, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFF]
    try forAll(iterations: 300, seed: 0xD03_0402) { random in
      let units = (0..<random.int(in: 0...12)).map { _ in random.pick(from: alphabet) }
      guard Array(JSText.string(fromCodeUnits: units).utf16) == pairedUnitsOnly(units) else { throw Mismatch(description: "decoded \(units) differently") }
    }
  }

  private func pairedUnitsOnly(_ units: [UInt16]) -> [UInt16] {
    let high: ClosedRange<UInt16> = 0xD800...0xDBFF
    let low: ClosedRange<UInt16> = 0xDC00...0xDFFF
    var kept: [UInt16] = []
    var index = 0
    while index < units.count {
      let unit = units[index]
      if high.contains(unit), index + 1 < units.count, low.contains(units[index + 1]) {
        kept += [unit, units[index + 1]]
        index += 2
        continue
      }
      if !high.contains(unit), !low.contains(unit) { kept.append(unit) }
      index += 1
    }
    return kept
  }
}
