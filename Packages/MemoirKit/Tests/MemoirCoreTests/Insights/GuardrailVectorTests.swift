import Foundation
import ShadowTestSupport
import ShadowText
import Testing

@testable import MemoirCore

@Suite("Insight guardrail vectors", TestTimeLimit.standard)
struct GuardrailVectorTests {
  @Test func shouldMatchTheReferenceOnEveryGuardrailCase() throws {
    let fixture = try InsightFixture.json("guardrails/guardrails.json")
    var mismatches: [String] = []
    var count = 0
    for group in ["spec", "seeded"] {
      for vector in try InsightFixture.array(fixture, group) {
        let input = try InsightFixture.object(vector, "input")
        let outcome = InsightGuardrails.apply(
          GuardrailInput(
            question: try InsightFixture.string(input, "queryText"), sensitiveSources: try InsightFixture.strings(input, "sensitiveSources"),
            allowedQuestIDs: try InsightFixture.strings(input, "allowedQuestIds"), draft: try InsightDraft(parsing: try InsightFixture.value(input, "draft"))))
        let expected = try InsightFixture.value(vector, "output").jsonText
        if InsightFixture.json(of: outcome).jsonText != expected { mismatches.append(try InsightFixture.string(vector, "id")) }
        count += 1
      }
    }
    #expect(count > 1_300)
    #expect(mismatches.isEmpty, "\(mismatches.count) cases differ, first: \(mismatches.prefix(10))")
  }

  @Test func shouldFindTheSameVerbatimQuoteAsTheReference() throws {
    var mismatches: [String] = []
    for vector in try InsightFixture.array(try InsightFixture.json("guardrails/quotes.json"), "cases") {
      let found = InsightGuardrails.findVerbatimQuote(in: try InsightFixture.string(vector, "output"), sources: try InsightFixture.strings(vector, "sources"))
      if found.map(OrderedJSON.string) ?? .null != (try InsightFixture.value(vector, "quote")) { mismatches.append(try InsightFixture.string(vector, "id")) }
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
  }

  @Test func shouldParseDraftsAsTheReferenceDoes() throws {
    var mismatches: [String] = []
    for vector in try InsightFixture.array(try InsightFixture.json("guardrails/parse.json"), "cases") {
      let output = try InsightFixture.object(vector, "output")
      let native: OrderedJSON
      do {
        let draft = try InsightDraft(parsing: try OrderedJSON(parsing: try InsightFixture.string(vector, "raw")))
        native = .object(OrderedJSONObject([(key: "draft", value: draft.json)]))
      } catch let error as InsightError {
        native = .object(OrderedJSONObject([(key: "error", value: .string(error.code == "insight.unusable_answer" ? "AI_009" : error.code))]))
      }
      if native.jsonText != output.jsonText { mismatches.append(try InsightFixture.string(vector, "id")) }
    }
    #expect(mismatches.isEmpty, "\(mismatches)")
  }

  @Test func shouldBuildTheReferencePromptWordForWord() throws {
    let contract = try InsightFixture.json("guardrails/contract.json")
    #expect(InsightPrompt.system == (try InsightFixture.string(contract, "systemPrompt")))
    #expect(InsightGuardrails.crisisResponseAnswer == (try InsightFixture.string(contract, "crisisResponseAnswer")))
    #expect(InsightGuardrails.allowedSuggestionKinds == (try InsightFixture.strings(contract, "allowedSuggestionKinds")))
    for vector in try InsightFixture.array(try InsightFixture.json("guardrails/prompts.json"), "cases") {
      let output = try InsightFixture.object(vector, "output")
      #expect(InsightPrompt.system == (try InsightFixture.string(output, "systemPrompt")))
      let user = InsightPrompt.user(question: try InsightFixture.string(vector, "queryText"), context: try InsightFixture.value(vector, "context"))
      #expect(user == (try InsightFixture.string(output, "userPrompt")))
    }
  }

  @Test func shouldCheckAVeryLongSourceListQuickly() {
    let words = (0..<40_000).map { "w\($0 % 977)x\($0 / 977)" }
    let sources = stride(from: 0, to: words.count, by: 40).map { words[$0..<min($0 + 40, words.count)].joined(separator: " ") }
    let output = String(repeating: "Evening quests slip on weekdays and recover on weekends. ", count: 150)
    let clock = ContinuousClock()
    let elapsed = clock.measure { #expect(InsightGuardrails.findVerbatimQuote(in: output, sources: sources) == nil) }
    #expect(elapsed < .seconds(5))
    #expect(InsightGuardrails.findVerbatimQuote(in: output + sources[500], sources: sources) != nil)
  }

  @Test func shouldFindARunExactlyWhereASubstringSearchDoes() {
    var generator = SeededGenerator(seed: 1121)
    let alphabet = ["a", "b", "ab", "ba", "aa", "b1", "1"]
    for _ in 0..<3_000 {
      let text = (0..<Int.random(in: 1...30, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? "a" }.joined(separator: " ")
      let run = (0..<Int.random(in: 3...7, using: &generator)).map { _ in alphabet.randomElement(using: &generator) ?? "a" }
      #expect(NormalizedWords(text).contains(run[...]) == text.contains(run.joined(separator: " ")), "\(run) in \(text)")
    }
  }
}

enum InsightFixture {
  struct Malformed: Error, CustomStringConvertible {
    let description: String
  }

  static func json(_ path: String) throws -> OrderedJSON {
    try OrderedJSON(parsing: String(decoding: try MemoirStoreFixture.fixture(path), as: UTF8.self))
  }

  static func value(_ json: OrderedJSON, _ key: String) throws -> OrderedJSON {
    guard let value = json.objectValue?[key] else { throw Malformed(description: "no \(key)") }
    return value
  }

  static func object(_ json: OrderedJSON, _ key: String) throws -> OrderedJSON {
    let value = try value(json, key)
    guard value.objectValue != nil else { throw Malformed(description: "\(key) is not an object") }
    return value
  }

  static func array(_ json: OrderedJSON, _ key: String) throws -> [OrderedJSON] {
    guard let items = try value(json, key).arrayValue else { throw Malformed(description: "\(key) is not an array") }
    return items
  }

  static func string(_ json: OrderedJSON, _ key: String) throws -> String {
    guard let text = try value(json, key).stringValue else { throw Malformed(description: "\(key) is not a string") }
    return text
  }

  static func strings(_ json: OrderedJSON, _ key: String) throws -> [String] {
    try array(json, key).map { item in
      guard let text = item.stringValue else { throw Malformed(description: "\(key) holds a non-string") }
      return text
    }
  }

  /// The reference's outcome shape, in its key order (guardrails.ts:13-17).
  static func json(of outcome: GuardrailOutcome) -> OrderedJSON {
    let violations = { (list: [GuardrailViolation]) in OrderedJSON.array(list.map { .string($0.rawValue) }) }
    let pairs: [(key: String, value: OrderedJSON)]
    switch outcome {
    case .passed(let draft): pairs = [(key: "status", value: .string("passed")), (key: "result", value: draft.json), (key: "violations", value: .array([]))]
    case .sanitized(let draft, let list): pairs = [(key: "status", value: .string("sanitized")), (key: "result", value: draft.json), (key: "violations", value: violations(list))]
    case .crisis(let draft): pairs = [(key: "status", value: .string("crisis")), (key: "result", value: draft.json)]
    case .blocked(let list): pairs = [(key: "status", value: .string("blocked")), (key: "violations", value: violations(list))]
    }
    return .object(OrderedJSONObject(pairs))
  }
}
