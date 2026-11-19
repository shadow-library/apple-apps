import Foundation
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let oracleFunction = """
  s => {
    let value;
    try { value = JSON.parse(s); } catch (error) { return ['E']; }
    const out = ['K'];
    const walk = (x) => {
      if (x === null) out.push('z');
      else if (typeof x === 'boolean') out.push(x ? 't' : 'f');
      else if (typeof x === 'number') out.push('n' + (Object.is(x, -0) ? '-0' : String(x)));
      else if (typeof x === 'string') out.push('s' + x);
      else if (Array.isArray(x)) { out.push('['); x.forEach(walk); out.push(']'); }
      else { out.push('{'); for (const k of Object.keys(x)) { out.push('k' + k); walk(x[k]); } out.push('}'); }
    };
    walk(value);
    return out;
  }
  """

private func units(_ text: String) -> [UInt16] {
  Array(text.utf16)
}

private func flatten(_ value: OrderedJSON, into out: inout [[UInt16]]) {
  switch value {
  case .null: out.append(units("z"))
  case .bool(let flag): out.append(units(flag ? "t" : "f"))
  case .int(let number): out.append(units("n" + Double(number).jsString))
  case .double(let number): out.append(units("n" + (number == 0 && number.sign == .minus ? "-0" : number.jsString)))
  case .string(let text): out.append(units("s" + text))
  case .array(let items):
    out.append(units("["))
    for item in items { flatten(item, into: &out) }
    out.append(units("]"))
  case .object(let object):
    out.append(units("{"))
    for entry in object.entries {
      out.append(units("k" + entry.key))
      flatten(entry.value, into: &out)
    }
    out.append(units("}"))
  }
}

private func expectedTokens(_ oracle: JSOracleValue) throws -> [[UInt16]]? {
  guard case .array(let values) = oracle else { throw Mismatch(description: "the oracle returned \(oracle)") }
  let tokens = try values.map { value -> [UInt16] in
    guard case .string(let raw) = value else { throw Mismatch(description: "the oracle returned a token \(value)") }
    return raw
  }
  if tokens == [units("E")] { return nil }
  return tokens.dropFirst().map { Array(JSText.string(fromCodeUnits: $0).utf16) }
}

private func check(_ document: String, with oracle: JSOracle) throws -> Bool {
  let expected = try expectedTokens(oracle.call(oracleFunction, .string(document)))
  let parsed = try? OrderedJSON(parsing: document)
  guard let expected else {
    guard parsed == nil else { throw Mismatch(description: "accepted \(describe(document)) but JSON.parse throws") }
    return false
  }
  guard let parsed else { throw Mismatch(description: "rejected \(describe(document)) but JSON.parse accepts it") }
  var actual: [[UInt16]] = []
  flatten(parsed, into: &actual)
  guard actual == expected else {
    throw Mismatch(
      description: "\(describe(document)): Swift \(actual.map { String(decoding: $0, as: UTF16.self) }) but JavaScript \(expected.map { String(decoding: $0, as: UTF16.self) })")
  }
  return true
}

private let jsonWhitespace = [" ", "\t", "\n", "\r"]
private let keyPool = [
  "a", "b", "", "1", "0", "2", "10", "01", "-1", "-0", "4294967294", "4294967295", "4294967296", "9007199254740991", "9007199254740992", "__proto__", "constructor", "toString",
  "é", "e\u{301}", "😀", "a b", "\\u0061", "\\u00e9", "\\n", "\\\"", "x\u{2028}",
]
private let stringPieces = [
  "a", "bc", " ", "é", "e\u{301}", "😀", "\u{2028}", "\u{7F}", "中", "\\n", "\\t", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\r", "\\u0000", "\\u001f", "\\u00e9", "\\u00E9",
  "\\ud83d\\ude00", "\\uD83D\\uDE00", "\\u2028", "\\uFEFF",
]
private let loneSurrogatePieces = ["\\ud800", "\\udc00", "\\ud83d", "\\ude00\\ud83d", "\\ud83d\\u0041", "\\udbff\\udfff", "\\ud83d\\\\ude00"]
private let numberPool = [
  "0", "-0", "1", "-1", "10", "1.5", "-1.5e3", "1E5", "1e+2", "1e-2", "0.1", "123456789012345678901234567890", "9223372036854775807", "9223372036854775808", "-9223372036854775808",
  "-9223372036854775809", "9007199254740993", "1e999", "-1e999", "1e-999", "0e0", "0.0", "-0.0", "-0e5", "5e-324", "1.7976931348623157e308", "100", "1.0", "0.30000000000000004",
  "4.35", "2e0",
]
private let junk = [
  "{", "}", "[", "]", ",", ":", "\"", "\\", "\u{A0}", "\u{FEFF}", "\u{2028}", "\u{B}", "\u{C}", "\u{85}", "\u{2003}", "\u{0}", "\u{1F}", "01", "+1", ".5", "1.", "tru", "nul",
  "NaN", "Infinity", "'a'", "//",
  "/**/", ",]", ",}", "\\x", "\\u12", "\\ud83", "e", "-", "0x1", "1e", "1e+",
]

private func randomDocument(_ random: inout SeededGenerator, depth: Int) -> String {
  func whitespace(_ random: inout SeededGenerator) -> String {
    random.chance(0.4) ? (0..<random.int(in: 1...2)).map { _ in random.pick(from: jsonWhitespace) }.joined() : ""
  }
  func string(_ random: inout SeededGenerator, allowLone: Bool) -> String {
    let pool = allowLone ? stringPieces + loneSurrogatePieces : stringPieces
    return "\"" + (0..<random.int(in: 0...4)).map { _ in random.pick(from: pool) }.joined() + "\""
  }
  switch random.int(in: 0...(depth > 0 ? 8 : 5)) {
  case 0: return "null"
  case 1: return random.chance(0.5) ? "true" : "false"
  case 2, 3: return random.pick(from: numberPool)
  case 4, 5: return string(&random, allowLone: true)
  case 6, 7:
    let items = (0..<random.int(in: 0...4)).map { _ in whitespace(&random) + randomDocument(&random, depth: depth - 1) + whitespace(&random) }
    return "[" + items.joined(separator: ",") + "]"
  default:
    let members = (0..<random.int(in: 0...5)).map { _ in
      whitespace(&random) + "\"" + random.pick(from: keyPool) + "\"" + whitespace(&random) + ":" + whitespace(&random) + randomDocument(&random, depth: depth - 1)
        + whitespace(&random)
    }
    return "{" + members.joined(separator: ",") + "}"
  }
}

private func mutated(_ document: String, _ random: inout SeededGenerator) -> String {
  var scalars = Array(document.unicodeScalars)
  for _ in 0..<random.int(in: 1...3) {
    let at = random.int(in: 0...scalars.count)
    let insertion = Array(random.pick(from: junk).unicodeScalars)
    switch random.int(in: 0...3) {
    case 0 where at < scalars.count: scalars.remove(at: at)
    case 1: scalars.insert(contentsOf: insertion, at: at)
    case 2 where at < scalars.count: scalars.replaceSubrange(at...at, with: insertion)
    default: scalars.removeSubrange(at...)
    }
  }
  var out = String.UnicodeScalarView()
  out.append(contentsOf: scalars)
  return String(out)
}

private func nested(_ depth: Int) -> String {
  String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
}

struct OrderedJSONParsingTests {
  @Test func shouldAcceptAndRejectExactlyWhatJSONParseDoesOnSeededDocuments() throws {
    let oracle = try JSOracle()
    var accepted = 0
    var rejected = 0
    var documents = 0
    try forAll(iterations: 700, seed: 0xD09_0501) { random in
      let base =
        random.chance(0.5) ? randomDocument(&random, depth: 3) : "{\"all\":[" + randomDocument(&random, depth: 2) + "]," + "\"k\":" + randomDocument(&random, depth: 3) + "}"
      let document = random.chance(0.45) ? mutated(base, &random) : base
      documents += 1
      if try check(document, with: oracle) { accepted += 1 } else { rejected += 1 }
    }
    #expect(documents >= 500 && accepted >= 200 && rejected >= 100, "accepted \(accepted), rejected \(rejected)")
  }

  @Test func shouldAgreeWithJSONParseOnHandPickedDocuments() throws {
    let oracle = try JSOracle()
    let documents = [
      "", " ", "1", " 1 ", "\t\n\r 1 \t\n\r", "\u{B}1", "\u{C}1", "\u{A0}1", "1\u{A0}", "\u{FEFF}1", "\u{2028}1", "\u{2003}[]", "[\u{85}]", "[\u{1680}1]",
      "[1,]", "[,1]", "[1 2]", "[1,,2]", "{\"a\":1,}", "{,}", "{\"a\"}", "{\"a\":}", "{a:1}", "{'a':1}", "{\"a\" 1}", "{\"a\":1 \"b\":2}", "[", "]", "{", "}", "[]]", "{}}",
      "[] []",
      "01", "-01", "00", "-", "--1", "+1", ".5", "1.", "1.e3", "1e", "1e+", "1E-", "0x10", "1_0", "Infinity", "-Infinity", "NaN", "1e999", "-1e999", "1e-999", "-0", "-0.0", "-0e1",
      "0e-0",
      "9223372036854775807", "9223372036854775808", "-9223372036854775808", "-9223372036854775809", "18446744073709551616", "123456789012345678901234567890", "9007199254740993",
      "0.1", "0.30000000000000004", "1.7976931348623157e308", "1.7976931348623159e308", "5e-324", "2.4703282292062327e-324", "2.4703282292062328e-324",
      "true", "false", "null", "tru", "truee", "True", "nulll", "undefined",
      "\"\"", "\"a\"", "\"a", "a\"", "\"\\\"", "\"\\x41\"", "\"\\u12\"", "\"\\u12G4\"", "\"\\u00e9\\u00E9\"", "\"\\/\\b\\f\\n\\r\\t\\\\\\\"\"", "\"\\a\"", "\"\\'\"", "\"\\\n\"",
      "\"\t\"", "\"\n\"", "\"\r\"", "\"\u{0}\"", "\"\u{1F}\"", "\"\u{7F}\"", "\"\u{2028}\u{2029}\"", "\"\u{FEFF}\"", "\"😀\"", "\"\\ud83d\\ude00\"", "\"\\ud83d\"", "\"\\ude00\"",
      "\"\\ude00\\ud83d\"",
      "\"\\ud83dx\"", "\"x\\ud83d\"", "\"\\ud83d\\u0041\"", "\"\\ud83d\\ud83d\\ude00\"", "\"\\uD83D\\uDE00\"", "\"\\u0000\"",
      "{\"a\":1,\"a\":2}", "{\"a\":1,\"b\":2,\"a\":3}", "{\"b\":1,\"2\":1,\"1\":1,\"-1\":1,\"a\":1,\"0\":1,\"01\":1}",
      "{\"4294967294\":1,\"4294967295\":2,\"4294967296\":3,\"1\":4}",
      "{\"9007199254740991\":1,\"9007199254740992\":2,\"5\":3}", "{\"__proto__\":1}", "{\"__proto__\":{\"a\":1},\"constructor\":2,\"toString\":3}",
      "{\"__proto__\":1,\"__proto__\":2}",
      "{\"\\u00e9\":1,\"e\\u0301\":2,\"\u{e9}\":3}", "{\"\\u0061\":1,\"a\":2}", "{\"\":1,\"\":2}", "{\"a\":{\"b\":{\"c\":[1,{\"d\":null}]}}}",
      nested(1), nested(2), nested(100), nested(OrderedJSON.maximumParsingDepth), "[" + nested(100) + "," + nested(100) + "]",
      "{\"a\":" + String(repeating: "{\"a\":", count: 100) + "1" + String(repeating: "}", count: 101),
    ]
    for document in documents { _ = try check(document, with: oracle) }
  }

  @Test func shouldReadNumbersAsIntegersOnlyWhenTheTextIsAnInt64WithoutFractionOrExponent() throws {
    #expect(try OrderedJSON(parsing: "0") == .int(0))
    #expect(try OrderedJSON(parsing: "-12") == .int(-12))
    #expect(try OrderedJSON(parsing: "9223372036854775807") == .int(Int64.max))
    #expect(try OrderedJSON(parsing: "-9223372036854775808") == .int(Int64.min))
    #expect(try OrderedJSON(parsing: "9223372036854775808") == .double(9_223_372_036_854_775_808))
    #expect(try OrderedJSON(parsing: "1e2") == .double(100))
    #expect(try OrderedJSON(parsing: "1.0") == .double(1))
    #expect(try OrderedJSON(parsing: "1e999") == .double(.infinity))
    guard case .double(let negativeZero) = try OrderedJSON(parsing: "-0") else { throw Mismatch(description: "-0 is not a double") }
    #expect(negativeZero == 0 && negativeZero.sign == .minus)
  }

  @Test func shouldDropAnUnpairedSurrogateEscapeAsTheToolkitRuleSays() throws {
    #expect(try OrderedJSON(parsing: "\"a\\ud800b\"") == .string("ab"))
    #expect(try OrderedJSON(parsing: "\"\\ude00\\ud83d\"") == .string(""))
    #expect(try OrderedJSON(parsing: "\"\\ud83d\\ude00\"") == .string("😀"))
  }

  @Test func shouldRefuseNestingBeyondTheLimitWithATypedErrorWithoutOverflowingTheStack() {
    #expect(throws: Never.self) { try OrderedJSON(parsing: nested(OrderedJSON.maximumParsingDepth)) }
    #expect(throws: OrderedJSONParseError.tooDeep(limit: 128)) { try OrderedJSON(parsing: nested(OrderedJSON.maximumParsingDepth + 1)) }
    #expect(throws: OrderedJSONParseError.tooDeep(limit: 128)) { try OrderedJSON(parsing: String(repeating: "[", count: 1_000_000)) }
    #expect(throws: OrderedJSONParseError.tooDeep(limit: 128)) { try OrderedJSON(parsing: String(repeating: "{\"a\":", count: 100_000)) }
  }

  @Test func shouldParseCompareCopyAndFreeAValueNestedToTheLimitOnAThreadWithASmallStack() throws {
    let outcome = Locked<Bool?>(nil)
    let thread = Thread {
      let text = String(repeating: "[", count: OrderedJSON.maximumParsingDepth) + String(repeating: "]", count: OrderedJSON.maximumParsingDepth)
      guard let first = try? OrderedJSON(parsing: text), let second = try? OrderedJSON(parsing: text) else {
        outcome.set(false)
        return
      }
      let copy = first
      outcome.set(first == second && copy == second)
    }
    thread.stackSize = 256 * 1024
    let finished = DispatchSemaphore(value: 0)
    let watcher = Thread {
      while outcome.get() == nil { Thread.sleep(forTimeInterval: 0.005) }
      finished.signal()
    }
    thread.start()
    watcher.start()
    #expect(finished.wait(timeout: .now() + 120) == .success)
    #expect(outcome.get() == true)
  }

  @Test func shouldReportTheByteOfASyntaxError() {
    #expect(throws: OrderedJSONParseError.syntax(offset: 3)) { try OrderedJSON(parsing: "[1,]") }
    #expect(throws: OrderedJSONParseError.syntax(offset: 0)) { try OrderedJSON(parsing: "") }
    #expect(OrderedJSONParseError.syntax(offset: 0).code == "ordered-json.syntax")
    #expect(OrderedJSONParseError.tooDeep(limit: 1).code == "ordered-json.too-deep")
  }

  @Test func shouldParseLargeInputsInOnePass() throws {
    let array = "[" + (0..<300_000).map(String.init).joined(separator: ",") + "]"
    guard case .array(let items) = try OrderedJSON(parsing: array) else { throw Mismatch(description: "not an array") }
    #expect(items.count == 300_000)
    let object = "{" + (0..<100_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",") + "}"
    guard case .object(let members) = try OrderedJSON(parsing: object) else { throw Mismatch(description: "not an object") }
    #expect(members.entries.count == 100_000)
  }
}

struct OrderedJSONTests {
  @Test func shouldListIntegerLikeKeysFirstInAscendingOrderThenTheRestAsInserted() {
    let value = OrderedJSONObject([(key: "b", value: .null), (key: "10", value: .null), (key: "a", value: .null), (key: "2", value: .null), (key: "-1", value: .null)])

    #expect(value.keys == ["2", "10", "b", "a", "-1"])
  }

  @Test func shouldKeepTheFirstPositionAndTheLastValueOfADuplicateKey() {
    let value = OrderedJSONObject([(key: "a", value: .int(1)), (key: "b", value: .int(2)), (key: "a", value: .int(3))])

    #expect(value.keys == ["a", "b"])
    #expect(value["a"] == .int(3))
  }

  @Test func shouldTellKeysApartThatDifferOnlyByUnicodeNormalisation() {
    let value = OrderedJSONObject([(key: "\u{e9}", value: .int(1)), (key: "e\u{301}", value: .int(2))])

    #expect(value.entries.count == 2)
    #expect(value["\u{e9}"] == .int(1))
    #expect(value["e\u{301}"] == .int(2))
  }

  @Test func shouldDistinguishAMissingKeyFromANullOne() {
    let value = OrderedJSONObject([(key: "a", value: .null)])

    #expect(value["a"] == .null)
    #expect(value["b"] == nil)
  }

  @Test func shouldKeepProtoAsAnOrdinaryKey() throws {
    let value = try OrderedJSON(parsing: "{\"__proto__\":1,\"constructor\":2}")

    #expect(value.objectValue?.keys == ["__proto__", "constructor"])
    #expect(value.objectValue?["__proto__"] == .int(1))
  }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func get() -> Value {
    lock.withLock { value }
  }

  func set(_ newValue: Value) {
    lock.withLock { value = newValue }
  }
}
