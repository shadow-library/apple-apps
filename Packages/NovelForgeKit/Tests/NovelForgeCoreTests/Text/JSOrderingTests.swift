import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

struct JSOrderingTests {
  private let iterations = 300

  @Test func shouldOrderStringsByCodeUnits() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0201) { random in
      let left = random.jsText(maxPieces: 3)
      let right = random.chance(0.3) ? left.jsNormalize(.nfd) : random.jsText(maxPieces: 3)
      try expectExactlySame(JSText.codeUnitPrecedes(left, right), oracle.call("(a, b) => a < b", .string(left), .string(right)), "\(describe(left)) < \(describe(right))")
    }
  }

  @Test func shouldSortAndDeduplicateLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0202) { random in
      let tricky: [String] = ["é", "e\u{301}", "😀", "\u{E000}", "a"]
      var values: [String] = []
      for _ in 0..<random.int(in: 0...8) { values.append(random.chance(0.3) ? random.pick(from: tricky) : random.jsText(maxPieces: 2)) }
      let label: String = values.map(describe).joined(separator: ", ")
      let distinct: Int = Set(values.map { JSString($0) }).count
      try expectExactlySame(values.jsSorted(), oracle.call("v => [...v].sort()", .strings(values)), label)
      try expectExactlySame(values.jsUnique(), oracle.call("v => [...new Set(v)]", .strings(values)), label)
      try expectExactlySame(distinct, oracle.call("v => new Set(v).size", .strings(values)), label)
    }
  }

  @Test func shouldSortStablyWithAComparatorLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0203) { random in
      let values = (0..<random.int(in: 0...10)).map { _ in random.jsText(maxPieces: 2) }
      let swift = values.jsStableSorted { $0.jsLength > $1.jsLength }
      try expectExactlySame(swift, oracle.call("v => [...v].sort((a, b) => b.length - a.length)", .strings(values)), values.map(describe).joined(separator: ", "))
    }
  }

  @Test func shouldSliceArraysLikeJavaScript() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0204) { random in
      let values = (0..<random.int(in: 0...6)).map { String($0) }
      let start = random.jsPosition(around: values.count)
      let end: Double? = random.chance(0.3) ? nil : random.jsPosition(around: values.count)
      let javaScript = try oracle.call("(v, a, b) => v.slice(a, b)", .strings(values), .number(start), end.map(JSOracleArgument.number) ?? .undefined)
      try expectExactlySame(values.jsSlice(JSNumber.integer(start), end.map(JSNumber.integer)), javaScript, "\(values).slice(\(start), \(String(describing: end)))")
    }
  }

  @Test func shouldOrderObjectKeysLikeJavaScript() throws {
    let oracle = try JSOracle()
    let candidates = ["0", "1", "2", "10", "01", "-1", "1.5", "4294967294", "4294967295", "99999999999", "a", "b", "é", "length", "", " 1", "1 "]
    try forAll(iterations: iterations, seed: 0xD03_0205) { random in
      let keys = Array(random.shuffled(candidates).prefix(random.int(in: 0...candidates.count)))
      let javaScript = try oracle.call("k => { const o = {}; for (const key of k) o[key] = 1; return Object.keys(o); }", .strings(keys))
      try expectExactlySame(JSText.ownPropertyKeyOrder(keys), javaScript, "\(keys)")
    }
  }

  @Test func shouldQuoteJSONStringsInShadowCoreLikeJSONStringify() throws {
    let oracle = try JSOracle()
    try forAll(iterations: iterations, seed: 0xD03_0206) { random in
      let text = random.jsText() + random.pick(from: ["", "\u{0}", "\u{8}", "\u{1F}", "\u{7F}", "\"", "\\", "/"])
      let swift = String(decoding: CanonicalJSON.encode(.string(text)), as: UTF8.self)
      try expectExactlySame(swift, oracle.call("s => JSON.stringify(s)", .string(text)), describe(text))
    }
  }

  @Test func shouldCollapseCanonicallyEquivalentKeysInShadowCoreJSONValue() {
    var members: [String: JSONValue] = [:]
    members["é"] = .int(1)
    members["e\u{301}"] = .int(2)
    #expect(JSONValue.object(members).objectValue?.count == 1)
  }
}
