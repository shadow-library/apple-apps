import ShadowTestSupport
import Testing

@testable import ShadowText

private let stringifyFunction = "s => JSON.stringify(JSON.parse(s))"

private let keys = ["a", "b", "", "1", "0", "2", "10", "01", "-1", "__proto__", "é", "e\u{301}", "😀", "a b", "q\\\"t", "x\u{2028}", "\\u0001"]
private let strings = [
  "a", "bc", " ", "é", "e\u{301}", "😀", "\u{2028}", "\u{7F}", "中", "\\n", "\\t", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\r", "\\u0000", "\\u001f", "\\u00e9", "\\ud83d\\ude00",
]
private let numbers = [
  "0", "-0", "1", "-1", "10", "1.5", "-1.5e3", "1E5", "1e+2", "1e-2", "0.1", "123456789012345678901234567890", "9223372036854775807", "-9223372036854775808", "9007199254740993",
  "9007199254740992", "1e999", "-1e999", "1e-999", "0e0", "0.0", "-0.0", "5e-324", "1.7976931348623157e308", "1e21", "1e-7", "0.000001", "100", "4.35", "123456789.123456789",
]

private func document(_ random: inout SeededGenerator, depth: Int) -> String {
  switch random.int(in: 0...(depth > 0 ? 8 : 5)) {
  case 0: return "null"
  case 1: return random.chance(0.5) ? "true" : "false"
  case 2, 3: return random.pick(from: numbers)
  case 4, 5: return "\"" + (0..<random.int(in: 0...4)).map { _ in random.pick(from: strings) }.joined() + "\""
  case 6, 7: return "[" + (0..<random.int(in: 0...4)).map { _ in document(&random, depth: depth - 1) }.joined(separator: " , ") + "]"
  default: return "{" + (0..<random.int(in: 0...5)).map { _ in "\"" + random.pick(from: keys) + "\" : " + document(&random, depth: depth - 1) }.joined(separator: ",") + "}"
  }
}

struct OrderedJSONStringifyTests {
  @Test func shouldStringifyExactlyAsJSONStringifyDoesOnSeededDocuments() throws {
    let oracle = try JSOracle()
    var checked = 0
    try forAll(iterations: 500, seed: 0xD12_57F1) { random in
      let text = document(&random, depth: 3)
      let expected = try oracle.call(stringifyFunction, .string(text))
      guard case .string(let units) = expected else { throw Mismatch(description: "the oracle returned \(expected)") }
      let actual = try OrderedJSON(parsing: text).jsonText
      let wanted = JSText.string(fromCodeUnits: units)
      #expect(Array(actual.utf16) == Array(wanted.utf16), "\(text): Swift \(actual) but JavaScript \(wanted)")
      checked += 1
    }
    #expect(checked >= 300)
  }

  @Test func shouldStringifyHandPickedDocumentsAsJSONStringifyDoes() throws {
    let oracle = try JSOracle()
    let documents = [
      "-0", "[-0,0,-0.0]", "9007199254740993", "[9223372036854775807,-9223372036854775808]", "1e21", "1e-7", "1e999", "[1e999,-1e999]", "{\"b\":1,\"2\":1,\"1\":1,\"a\":1}",
      "{\"a\":1,\"a\":2}", "\"\\u0001\\u001f\\u007f\\u2028é😀\"", "{\"\\u00e9\":1,\"e\\u0301\":2}", "[]", "{}", "[[],{},[{}]]", "0.1", "123456789012345678901234567890",
    ]
    for text in documents {
      guard case .string(let units) = try oracle.call(stringifyFunction, .string(text)) else { throw Mismatch(description: "no string for \(text)") }
      #expect(try OrderedJSON(parsing: text).jsonText == JSText.string(fromCodeUnits: units), "\(text)")
    }
  }
}
