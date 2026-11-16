import ShadowCore
import Testing

@testable import NovelForgeCore

struct ChangeSetElementTests {
  @Test func shouldDecodeAnElementWhoseNumbersAreAllInt64Integers() {
    let source = #"{ "op" : "a", "n": -9223372036854775808, "m": 9223372036854775807, "zero": -0, "list": [1, 2, {"k": 3}], "s": "1.5", "t": true, "u": null }"#
    let element = ChangeSetElement(source: source)
    #expect(element?.op == "a")
    #expect(
      element?.jsonValue
        == .object([
          "op": "a", "n": .int(.min), "m": .int(.max), "zero": 0, "list": [1, 2, ["k": 3]], "s": "1.5", "t": true, "u": nil,
        ]))
    #expect(element?.source == source)
  }

  @Test(arguments: [
    #"{"op":"a","n":1.5}"#,
    #"{"op":"a","n":1.0}"#,
    #"{"op":"a","n":1e2}"#,
    #"{"op":"a","n":1E+2}"#,
    #"{"op":"a","n":0e0}"#,
    #"{"op":"a","n":[1,[2,{"deep":-0.5}]]}"#,
    #"{"op":"a","n":9223372036854775808}"#,
    #"{"op":"a","n":-9223372036854775809}"#,
    #"{"op":"a","n":99999999999999999999999}"#,
  ])
  func shouldReturnNilForAFractionAnExponentOrAnOutOfRangeIntegerAndKeepTheRawText(source: String) {
    let element = ChangeSetElement(source: source)
    #expect(element != nil)
    #expect(element?.jsonValue == nil)
    #expect(element?.source == source)
  }

  @Test func shouldDecodeAnElementWhoseFractionLooksLikeNumbersOnlyInsideStrings() {
    #expect(ChangeSetElement(source: #"{"op":"a","note":"1.5 and 1e9"}"#)?.jsonValue == ["op": "a", "note": "1.5 and 1e9"])
  }

  @Test(arguments: [
    #"{"op":"a",}"#,
    #"{"op":"a"} x"#,
    #"{"op":"a","x":01}"#,
    #"{"op":"a","x":+1}"#,
    #"{"op":"a","x":.5}"#,
    #"{"op":"a","x":1.}"#,
    #"{"op":"a","x":-}"#,
    #"{"op":"a","x":NaN}"#,
    #"{"op":"a","x":'s'}"#,
    #"{op:"a"}"#,
    #"{"op":"a","x":"\q"}"#,
    #"{"op":"a","x":"\u12"}"#,
    "{\"op\":\"a\",\"x\":\"tab\there\"}",
    "{\"op\":\"a\"\u{00A0}}",
    #"{"op":7}"#,
    #"{"op":null}"#,
    #"{"op":"a","op":7}"#,
    #"{"OP":"a"}"#,
    #"{"x":"a"}"#,
    #"["op"]"#,
    #""op""#,
    #"{"op":"a","x":[1,2}"#,
    #"{"op":"a","x":{"y":1]}"#,
    "",
  ])
  func shouldRejectWhatJSONParseOrTheOpRuleRejects(source: String) {
    #expect(ChangeSetElement(source: source) == nil)
  }

  @Test func shouldTakeTheLastOpWhenTheKeyRepeatsAndDecodeEscapedKeys() {
    #expect(ChangeSetElement(source: #"{"op":7,"op":"later"}"#)?.op == "later")
    #expect(ChangeSetElement(source: #"{"o\u0070":"escaped"}"#)?.op == "escaped")
    #expect(ChangeSetElement(source: #"{"x":{"op":"nested"},"op":"top"}"#)?.op == "top")
  }

  @Test func shouldAcceptJSONWhitespaceBetweenEveryToken() {
    #expect(ChangeSetElement(source: "{ \t\n\r\"op\" \t:\r\n \"a\" \n, \"l\" : [ 1 , 2 ] }")?.op == "a")
  }
}
