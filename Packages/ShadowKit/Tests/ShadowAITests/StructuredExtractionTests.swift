import Foundation
import Testing

@testable import ShadowAI

@Suite("StructuredExtraction")
struct StructuredExtractionTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let label: String
    let text: String
    let expected: String?

    var testDescription: String { label }
  }

  private static func nested(_ depth: Int) -> String {
    String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
  }

  static let cases: [Case] = [
    Case(label: "bare object", text: #"{"verdict":"consistent","findings":[]}"#, expected: #"{"verdict":"consistent","findings":[]}"#),
    Case(label: "bare object with surrounding whitespace", text: "\n  {\"a\": 1}\n", expected: #"{"a": 1}"#),
    Case(label: "fenced with a language tag", text: "```json\n{\"verdict\":\"consistent\",\"findings\":[]}\n```", expected: #"{"verdict":"consistent","findings":[]}"#),
    Case(label: "fenced without a language tag", text: "```\n[1, 2.5]\n```", expected: "[1, 2.5]"),
    Case(label: "fence before a bracket in the prose", text: "Step [1] is done:\n```json\n{\"a\":1}\n```", expected: #"{"a":1}"#),
    Case(label: "prose before and after", text: "Certainly!\n{\"verdict\":\"consistent\"}\nHope that helps.", expected: #"{"verdict":"consistent"}"#),
    Case(
      label: "two objects, first wins",
      text: "Reasoning first: {\"note\":\"thinking out loud\"}\n\nFinal answer:\n{\"verdict\":\"consistent\",\"findings\":[]}",
      expected: #"{"note":"thinking out loud"}"#),
    Case(label: "array at top level in prose", text: #"Here they are: [{"a":1},{"a":2}] as asked."#, expected: #"[{"a":1},{"a":2}]"#),
    Case(label: "whole-text scalar", text: " 42 ", expected: "42"),
    Case(
      label: "closing brace inside a string",
      text: "Here is the verdict:\n{\"verdict\":\"consistent\",\"findings\":[{\"severity\":\"soft\",\"text\":\"the sigil closes with a } glyph\"}]}",
      expected: #"{"verdict":"consistent","findings":[{"severity":"soft","text":"the sigil closes with a } glyph"}]}"#),
    Case(label: "opening brace inside a string", text: #"{"reply":"the ward opens with a { and never shuts"}"#, expected: #"{"reply":"the ward opens with a { and never shuts"}"#),
    Case(label: "escaped quotes", text: #"So: {"reply":"she said \"close the } gate\" and left"}"#, expected: #"{"reply":"she said \"close the } gate\" and left"}"#),
    Case(label: "stray closing brace in the prose", text: "the previous draft ended } abruptly\n{\"verdict\":\"consistent\"}", expected: #"{"verdict":"consistent"}"#),
    Case(label: "balanced run that is not JSON", text: "use {placeholder} here\n{\"verdict\":\"consistent\"}", expected: #"{"verdict":"consistent"}"#),
    Case(label: "no JSON", text: "I cannot help with that request.", expected: nil),
    Case(label: "unbalanced", text: "no json here { at all", expected: nil),
    Case(label: "mismatched brackets", text: #"{"a": [1, 2}"#, expected: nil),
    Case(label: "truncated", text: #"{"chapters":[{"title":"One"},{"title":"Tw"#, expected: nil),
    Case(label: "empty text", text: "", expected: nil),
    Case(label: "nesting at the depth limit", text: nested(64), expected: nested(64)),
    Case(label: "nesting beyond the depth limit", text: nested(65), expected: nil),
    Case(label: "nesting beyond the limit yields no inner fragment", text: "[" + nested(64) + "] then {\"ok\":true}", expected: #"{"ok":true}"#),
    Case(label: "lone high surrogate is skipped", text: #"{"a":"\ud800"} then {"b":"ok"}"#, expected: #"{"b":"ok"}"#),
    Case(label: "lone low surrogate", text: #"{"a":"\udc00"}"#, expected: nil),
    Case(label: "surrogate pair", text: #"{"a":"😀"}"#, expected: #"{"a":"😀"}"#),
  ]

  @Test("should extract the first JSON value from loose text", arguments: cases)
  func extracts(_ testCase: Case) throws {
    let extracted = StructuredExtraction.json(in: testCase.text)
    #expect(extracted.map { String(decoding: $0, as: UTF8.self) } == testCase.expected)
    if let extracted { _ = try JSONSerialization.jsonObject(with: extracted, options: [.fragmentsAllowed]) }
  }

  @Test("should list every candidate in order without duplicates")
  func listsCandidates() {
    let bytes = Array("Reasoning first: {\"note\":\"thinking\"}\n\nFinal answer:\n```json\n{\"verdict\":\"consistent\"}\n```".utf8)
    let texts = StructuredExtraction.candidates(in: bytes).map { String(decoding: bytes[$0.range], as: UTF8.self) }
    #expect(texts == [#"{"verdict":"consistent"}"#, #"{"note":"thinking"}"#])
  }

  @Test("should give up quickly on a megabyte of text without JSON")
  func handlesLargeProse() {
    let prose = String(repeating: "The night was long and the ward held. ", count: 28_000)
    let braces = String(repeating: "{", count: 1_000_000)
    let clock = ContinuousClock()
    let elapsed = clock.measure {
      #expect(StructuredExtraction.json(in: prose) == nil)
      #expect(StructuredExtraction.json(in: braces) == nil)
    }
    #expect(elapsed < .seconds(2))
  }
}
