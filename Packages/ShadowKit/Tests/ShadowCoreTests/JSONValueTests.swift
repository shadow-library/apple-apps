import Foundation
import ShadowCore
import Testing

@Suite("JSONValue")
struct JSONValueTests {
  @Test("should build values from literals")
  func buildsFromLiterals() {
    let value: JSONValue = ["a": [1, true, nil, "x"], "b": ["c": -5]]
    #expect(value["a"]?[0] == .int(1))
    #expect(value["a"]?[1] == .bool(true))
    #expect(value["a"]?[2] == .null)
    #expect(value["a"]?[3] == .string("x"))
    #expect(value["b"]?["c"] == .int(-5))
  }

  @Test("should keep the last value for a repeated dictionary literal key")
  func lastLiteralKeyWins() {
    let value: JSONValue = ["a": 1, "a": 2]
    #expect(value == .object(["a": .int(2)]))
  }

  @Test("should expose symmetric accessors returning nil for other cases")
  func accessors() {
    #expect(JSONValue.null.isNull)
    #expect(JSONValue.bool(true).boolValue == true)
    #expect(JSONValue.int(3).intValue == 3)
    #expect(JSONValue.string("s").stringValue == "s")
    #expect(JSONValue.array([1]).arrayValue == [.int(1)])
    #expect(JSONValue.object(["k": 1]).objectValue == ["k": .int(1)])
    #expect(JSONValue.int(3).boolValue == nil)
    #expect(JSONValue.bool(true).intValue == nil)
    #expect(JSONValue.null.stringValue == nil)
    #expect(JSONValue.string("s").arrayValue == nil)
    #expect(JSONValue.array([]).objectValue == nil)
    #expect(JSONValue.string("s").isNull == false)
    #expect(JSONValue.int(1)["k"] == nil)
    #expect(JSONValue.array([1])[5] == nil)
    #expect(JSONValue.array([1])[-1] == nil)
    #expect(JSONValue.object([:])["k"] == nil)
  }

  @Test("should round trip through JSONEncoder and JSONDecoder")
  func codableRoundTrip() throws {
    let value: JSONValue = ["n": nil, "t": true, "i": 9_223_372_036_854_775_807, "m": -9_223_372_036_854_775_808, "s": "héllo", "a": [1, [2]], "o": ["k": "v"]]
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(JSONValue.self, from: data) == value)
  }

  @Test("should decode a top-level scalar through JSONDecoder")
  func decodesScalars() throws {
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("null".utf8)) == .null)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("true".utf8)) == .bool(true))
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data("7".utf8)) == .int(7))
  }

  @Test("should throw a DecodingError for fractional or out of range numbers")
  func rejectsNonIntegers() {
    for text in ["1.5", "1e400", "18446744073709551615", "[0.25]", "{\"a\":2.5}"] {
      #expect(throws: DecodingError.self) { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
    }
  }
}
