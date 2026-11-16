import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

private func bytes(_ text: String) -> Data {
  Data(text.utf8)
}

private func encoded(_ value: JSONValue) -> String {
  String(decoding: CanonicalJSON.encode(value), as: UTF8.self)
}

private func decoded(_ input: Data, mode: CanonicalJSON.DecodingMode = .canonical) throws -> JSONValue {
  do {
    return try CanonicalJSON.decode(input, mode: mode)
  } catch {
    throw error
  }
}

private func failure(_ input: Data, _ mode: CanonicalJSON.DecodingMode) -> CanonicalJSONError? {
  do {
    _ = try CanonicalJSON.decode(input, mode: mode)
    return nil
  } catch {
    return error
  }
}

private func failure(_ text: String, _ mode: CanonicalJSON.DecodingMode) -> CanonicalJSONError? {
  failure(bytes(text), mode)
}

private func randomValue(_ generator: inout SeededGenerator, depth: Int = 0) -> JSONValue {
  switch generator.int(in: 0...(depth >= 4 ? 3 : 5)) {
  case 0: return .null
  case 1: return .bool(generator.chance(0.5))
  case 2: return .int(Int64(bitPattern: generator.next()) >> generator.int(in: 0...63))
  case 3: return .string(generator.unicodeString(maxLength: 12))
  case 4: return .array((0..<generator.int(in: 0...4)).map { _ in randomValue(&generator, depth: depth + 1) })
  default:
    var members = [String: JSONValue]()
    for _ in 0..<generator.int(in: 0...4) { members[generator.unicodeString(maxLength: 6)] = randomValue(&generator, depth: depth + 1) }
    return .object(members)
  }
}

private func reordered(_ value: JSONValue, _ generator: inout SeededGenerator) -> JSONValue {
  switch value {
  case .array(let elements):
    return .array(elements.map { reordered($0, &generator) })
  case .object(let members):
    var rebuilt = [String: JSONValue](minimumCapacity: generator.int(in: 0...64))
    for key in generator.shuffled(members.keys) { rebuilt[key] = reordered(members[key] ?? .null, &generator) }
    return .object(rebuilt)
  default:
    return value
  }
}

private func nested(_ depth: Int, object: Bool = false) -> String {
  guard object else { return String(repeating: "[", count: depth) + String(repeating: "]", count: depth) }
  return String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
}

@Suite("CanonicalJSON encoding")
struct CanonicalJSONEncodingTests {
  @Test("should write scalars as literals")
  func scalars() {
    #expect(encoded(.null) == "null")
    #expect(encoded(.bool(true)) == "true")
    #expect(encoded(.bool(false)) == "false")
    #expect(encoded(.string("")) == "\"\"")
  }

  @Test("should write the full Int64 range without padding or signs")
  func integers() {
    #expect(encoded(.int(0)) == "0")
    #expect(encoded(.int(7)) == "7")
    #expect(encoded(.int(-7)) == "-7")
    #expect(encoded(.int(Int64.max)) == "9223372036854775807")
    #expect(encoded(.int(Int64.min)) == "-9223372036854775808")
  }

  @Test("should apply every RFC 8785 string escape rule")
  func escapes() {
    #expect(encoded("\"") == "\"\\\"\"")
    #expect(encoded("\\") == "\"\\\\\"")
    #expect(encoded("\u{08}") == "\"\\b\"")
    #expect(encoded("\t") == "\"\\t\"")
    #expect(encoded("\n") == "\"\\n\"")
    #expect(encoded("\u{0C}") == "\"\\f\"")
    #expect(encoded("\r") == "\"\\r\"")
    #expect(encoded("\u{00}") == "\"\\u0000\"")
    #expect(encoded("\u{01}") == "\"\\u0001\"")
    #expect(encoded("\u{0B}") == "\"\\u000b\"")
    #expect(encoded("\u{1F}") == "\"\\u001f\"")
  }

  @Test("should write everything else literally as UTF-8")
  func literals() {
    #expect(encoded("/") == "\"/\"")
    #expect(encoded("\u{7F}") == "\"\u{7F}\"")
    #expect(encoded("\u{2028}") == "\"\u{2028}\"")
    #expect(encoded("😀") == "\"😀\"")
    #expect(CanonicalJSON.encode("😀") == Data([0x22, 0xF0, 0x9F, 0x98, 0x80, 0x22]))
    #expect(CanonicalJSON.encode("\u{20}") == Data([0x22, 0x20, 0x22]))
  }

  @Test("should sort keys by UTF-16 code units per the RFC 8785 example")
  func rfcKeyOrder() {
    let value: JSONValue = [
      "\u{20AC}": "Euro Sign",
      "\r": "Carriage Return",
      "\u{FB33}": "Hebrew Letter Dalet With Dagesh",
      "1": "One",
      "\u{1F600}": "Emoji: Grinning Face",
      "\u{80}": "Control",
      "\u{F6}": "Latin Small Letter O With Diaeresis",
    ]
    let expected =
      "{\"\\r\":\"Carriage Return\",\"1\":\"One\",\"\u{80}\":\"Control\",\"\u{F6}\":\"Latin Small Letter O With Diaeresis\","
      + "\"\u{20AC}\":\"Euro Sign\",\"\u{1F600}\":\"Emoji: Grinning Face\",\"\u{FB33}\":\"Hebrew Letter Dalet With Dagesh\"}"
    #expect(encoded(value) == expected)
  }

  @Test("should write nested structures without whitespace")
  func nestedStructures() {
    let value: JSONValue = ["b": [1, [2, []], [:]], "a": ["z": nil, "y": [true]]]
    #expect(encoded(value) == "{\"a\":{\"y\":[true],\"z\":null},\"b\":[1,[2,[]],{}]}")
  }

  @Test("should never normalise strings")
  func keepsNormalisation() {
    #expect(CanonicalJSON.encode("e\u{301}") == bytes("\"e\u{301}\""))
    #expect(CanonicalJSON.encode("\u{E9}") == bytes("\"\u{E9}\""))
    #expect(CanonicalJSON.encode("e\u{301}") != CanonicalJSON.encode("\u{E9}"))
  }

  @Test("should produce the same bytes regardless of insertion order")
  func insertionOrderIndependent() throws {
    try forAll { generator in
      let value = randomValue(&generator)
      #expect(CanonicalJSON.encode(reordered(value, &generator)) == CanonicalJSON.encode(value))
    }
  }
}

@Suite("CanonicalJSON decoding")
struct CanonicalJSONDecodingTests {
  @Test("should round trip random values in canonical mode")
  func roundTrip() throws {
    try forAll(iterations: 500) { generator in
      let value = randomValue(&generator)
      let data = CanonicalJSON.encode(value)
      let canonical = try decoded(data, mode: .canonical)
      let lenient = try decoded(data, mode: .lenient)
      #expect(canonical == value)
      #expect(lenient == value)
    }
  }

  @Test("should default to canonical mode")
  func defaultsToCanonical() throws {
    #expect(try decoded(bytes("[1]")) == [1])
    #expect(failure(" [1]", .canonical) == .notCanonical)
    #expect(throws: CanonicalJSONError.notCanonical) { try CanonicalJSON.decode(bytes(" [1]")) }
  }

  @Test("should decode integer extremes")
  func integerExtremes() throws {
    #expect(try decoded(bytes("9223372036854775807")) == .int(Int64.max))
    #expect(try decoded(bytes("-9223372036854775808")) == .int(Int64.min))
    #expect(try decoded(bytes("0")) == .int(0))
    #expect(try decoded(bytes("-1")) == .int(-1))
  }

  @Test("should decode data slices with a non-zero start index")
  func decodesSlices() throws {
    let padded = bytes("xx{\"a\":1}yy")
    #expect(try decoded(padded[2..<9]) == ["a": 1])
  }

  @Test("should reject unsupported numbers in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsNumbers(mode: CanonicalJSON.DecodingMode) {
    for text in ["1.0", "1.5", "0.5", "1e3", "1E3", "1e+3", "-1.5", "9223372036854775808", "-9223372036854775809", "99999999999999999999999999", "-0"] {
      guard case .numberNotInt64? = failure(text, mode) else {
        Issue.record("expected numberNotInt64 for \(text), got \(String(describing: failure(text, mode)))")
        continue
      }
    }
    for text in ["01", "-01", "00", "+1", "-", "- 1", ".5", "1.", "0x10", "1a", "NaN", "Infinity", "-Infinity"] {
      #expect(failure(text, mode) != nil, "\(text)")
    }
    #expect(failure("01", mode) == .invalidSyntax(offset: 1))
  }

  @Test("should reject malformed syntax in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsSyntax(mode: CanonicalJSON.DecodingMode) {
    for text in [
      "", " ", "[", "]", "{", "}", "[1,]", "[,1]", "[1 2]", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "{,}", "{1:2}", "{'a':1}", "tru", "truee", "nul", "True", "\"abc", "[1] x", "1 2",
      "{} {}", "\u{FEFF}[]",
    ] {
      #expect(failure(text, mode) != nil, "\(text)")
    }
    #expect(failure("", mode) == .invalidSyntax(offset: 0))
    #expect(failure("[1] x", mode) == .invalidSyntax(offset: 4))
  }

  @Test("should reject duplicate keys in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsDuplicateKeys(mode: CanonicalJSON.DecodingMode) {
    #expect(failure("{\"a\":1,\"a\":2}", mode) == .duplicateKey(offset: 7))
    #expect(failure("{\"a\":1,\"\\u0061\":2}", mode) == .duplicateKey(offset: 7))
    #expect(failure("{\"x\":{\"a\":1,\"a\":1}}", mode) == .duplicateKey(offset: 12))
  }

  @Test("should reject keys that differ only by normalisation in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsNormalisationDuplicates(mode: CanonicalJSON.DecodingMode) {
    let precomposed = "{\"\u{E9}\":1,\"e\u{301}\":2}"
    let decomposedFirst = "{\"e\u{301}\":1,\"\u{E9}\":2}"
    #expect(failure(precomposed, mode) == .duplicateKey(offset: 8))
    #expect(failure(decomposedFirst, mode) == .duplicateKey(offset: 9))
  }

  @Test("should reject invalid UTF-8 in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsInvalidUTF8(mode: CanonicalJSON.DecodingMode) {
    let invalid: [[UInt8]] = [[0xFF], [0xC0, 0xAF], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xC3], [0x80]]
    for sequence in invalid {
      let input = Data([0x22] + sequence + [0x22])
      #expect(failure(input, mode) == .invalidUTF8(offset: 0), "\(sequence)")
    }
    #expect(failure(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]), mode) == .invalidUTF8(offset: 1))
  }

  @Test("should reject invalid escapes in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsInvalidEscapes(mode: CanonicalJSON.DecodingMode) {
    for text in [
      "\"\\x\"", "\"\\a\"", "\"\\'\"", "\"\\u12\"", "\"\\u12G4\"", "\"\\ud800\"", "\"\\ud800x\"", "\"\\ud800\\u0041\"", "\"\\udc00\"", "\"\\udc00\\ud800\"", "\"\\ud800\\ud800\"",
    ] {
      guard case .invalidEscape? = failure(text, mode) else {
        Issue.record("expected invalidEscape for \(text), got \(String(describing: failure(text, mode)))")
        continue
      }
    }
    #expect(failure("\"\\", mode) != nil)
    #expect(failure("\"\\u", mode) != nil)
  }

  @Test("should reject unescaped control characters in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func rejectsControlCharacters(mode: CanonicalJSON.DecodingMode) {
    for byte in UInt8(0)..<0x20 {
      #expect(failure(Data([0x22, byte, 0x22]), mode) == .invalidSyntax(offset: 1), "\(byte)")
    }
  }

  @Test("should accept nesting at the maximum depth and reject one deeper in both modes", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func depthLimit(mode: CanonicalJSON.DecodingMode) throws {
    #expect(CanonicalJSON.maximumDepth == 64)
    #expect(try decoded(bytes(nested(64)), mode: mode) != nil)
    #expect(try decoded(bytes(nested(64, object: true)), mode: mode) != nil)
    guard case .nestingTooDeep? = failure(nested(65), mode) else {
      Issue.record("expected nestingTooDeep for arrays")
      return
    }
    guard case .nestingTooDeep? = failure(nested(65, object: true), mode) else {
      Issue.record("expected nestingTooDeep for objects")
      return
    }
  }

  @Test("should not recurse without bound on hostile nesting", arguments: [CanonicalJSON.DecodingMode.canonical, .lenient])
  func hostileNesting(mode: CanonicalJSON.DecodingMode) {
    #expect(failure(String(repeating: "[", count: 1_000_000), mode) == .nestingTooDeep(offset: 64))
    #expect(failure(String(repeating: "{\"a\":", count: 1_000_000), mode) == .nestingTooDeep(offset: 64 * 5))
  }

  @Test("should accept in lenient mode what canonical mode rejects")
  func lenientOnly() throws {
    let cases: [(String, JSONValue)] = [
      (" [ 1 , 2 ] ", [1, 2]),
      ("\n{\t\"a\" :\r1 }\n", ["a": 1]),
      ("{\"b\":1,\"a\":2}", ["a": 2, "b": 1]),
      ("\"\\u0041\"", "A"),
      ("\"\\/\"", "/"),
      ("\"\\u00E9\"", "\u{E9}"),
      ("\"\\u001F\"", "\u{1F}"),
      ("\"\\u0008\"", "\u{08}"),
      ("\"\\u000A\"", "\n"),
      ("\"\\ud83d\\ude00\"", "😀"),
      ("\"\\uD83D\\uDE00\"", "😀"),
      ("\"\\u0022\"", "\""),
      ("\"\\u005c\"", "\\"),
    ]
    for (text, expected) in cases {
      #expect(try decoded(bytes(text), mode: .lenient) == expected, "\(text)")
      #expect(failure(text, .canonical) == .notCanonical, "\(text)")
    }
  }

  @Test("should accept canonical output of non-minimal escape targets only in their minimal form")
  func canonicalMinimalEscapes() throws {
    for text in ["\"\\n\"", "\"\\u0000\"", "\"\\u0001\"", "\"\\u001f\"", "\"/\"", "\"\u{7F}\"", "\"\u{2028}\"", "\"😀\"", "\"\\\"\"", "\"\\\\\""] {
      #expect(failure(text, .canonical) == nil, "\(text)")
    }
  }

  @Test("should reject unsorted keys in canonical mode only")
  func unsortedKeys() throws {
    #expect(failure("{\"b\":1,\"a\":2}", .canonical) == .notCanonical)
    #expect(failure("{\"\u{1F600}\":1,\"\u{FB33}\":2}", .canonical) == nil)
    #expect(failure("{\"\u{FB33}\":1,\"\u{1F600}\":2}", .canonical) == .notCanonical)
    #expect(try decoded(bytes("{\"\u{FB33}\":1,\"\u{1F600}\":2}"), mode: .lenient).objectValue?.count == 2)
  }

  @Test("should preserve normalisation-distinct strings byte for byte")
  func preservesNormalisation() throws {
    let decomposed = bytes("\"e\u{301}\"")
    #expect(Array(CanonicalJSON.encode(try decoded(decomposed))) == Array(decomposed))
    let precomposed = bytes("\"\u{E9}\"")
    #expect(Array(CanonicalJSON.encode(try decoded(precomposed))) == Array(precomposed))
  }

  @Test("should have a code and description for every error")
  func errorMetadata() {
    let errors: [CanonicalJSONError] = [
      .invalidSyntax(offset: 1), .duplicateKey(offset: 2), .numberNotInt64(offset: 3), .invalidUTF8(offset: 4), .invalidEscape(offset: 5), .nestingTooDeep(offset: 6),
      .notCanonical,
    ]
    #expect(Set(errors.map(\.code)).count == errors.count)
    #expect(errors.allSatisfy { $0.errorDescription?.isEmpty == false })
  }

  @Test("should never crash on random bytes")
  func randomBytesNeverCrash() throws {
    try forAll(iterations: 2000) { generator in
      let input = generator.data(count: generator.int(in: 0...64))
      _ = try? CanonicalJSON.decode(input, mode: .lenient)
      _ = try? CanonicalJSON.decode(input, mode: .canonical)
    }
  }

  @Test("should never crash on mutated valid documents and keep canonical decode consistent")
  func mutatedDocuments() throws {
    try forAll(iterations: 1000) { generator in
      var data = Array(CanonicalJSON.encode(randomValue(&generator)))
      for _ in 0..<generator.int(in: 0...3) where !data.isEmpty { data[generator.int(in: 0...(data.count - 1))] = UInt8(truncatingIfNeeded: generator.next()) }
      guard let value = try? CanonicalJSON.decode(Data(data), mode: .canonical) else { return }
      #expect(Array(CanonicalJSON.encode(value)) == data)
    }
  }
}
