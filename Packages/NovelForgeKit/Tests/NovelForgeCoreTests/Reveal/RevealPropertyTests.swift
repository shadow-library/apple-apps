import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let keyPool = ["all", "milestone", "volume", "chapter", "ending", "pov", "learns", "entityKey", "factKey", "x", "1", "0", "é", "e\u{301}", "", " "]

private func randomJSON(_ generator: inout SeededGenerator, depth: Int) -> OrderedJSON {
  switch generator.int(in: 0...(depth > 0 ? 8 : 5)) {
  case 0: return .null
  case 1: return .bool(generator.chance(0.5))
  case 2: return .int(Int64(generator.int(in: -3...20)))
  case 3: return .double(Double(generator.int(in: -40...40)) / 4)
  case 4: return .string(generator.chance(0.5) ? generator.pick(from: keyPool) : generator.unicodeString(maxLength: 6))
  case 5: return .string(generator.pick(from: ["a", "lamp", " "]))
  case 6, 7: return .array((0..<generator.int(in: 0...3)).map { _ in randomJSON(&generator, depth: depth - 1) })
  default:
    let pairs = (0..<generator.int(in: 0...4)).map { _ in (key: generator.pick(from: keyPool), value: randomJSON(&generator, depth: depth - 1)) }
    return .object(OrderedJSONObject(pairs))
  }
}

private func randomTerm(_ generator: inout SeededGenerator) -> UnlockTerm {
  switch generator.int(in: 0...3) {
  case 0: .milestone(generator.pick(from: ["lamp_rank_4", "lamp_rank_5", "é", "e\u{301}"]))
  case 1: .volume(generator.pick(from: ["the_tower", "the_sea", "é", "e\u{301}"]))
  case 2: .chapter(generator.int(in: 1...20))
  default: .ending
  }
}

private func json(_ term: UnlockTerm) -> OrderedJSON {
  switch term {
  case .milestone(let key): object(("milestone", .string(key)))
  case .volume(let key): object(("volume", .string(key)))
  case .chapter(let number): object(("chapter", .int(Int64(number))))
  case .ending: object(("ending", .bool(true)))
  }
}

private func randomContext(_ generator: inout SeededGenerator) -> UnlockContext {
  UnlockContext(
    chapter: generator.int(in: -2...25),
    endingChapter: generator.chance(0.5) ? nil : generator.int(in: -2...25),
    volumeKey: generator.chance(0.3) ? nil : generator.pick(from: ["the_tower", "the_sea", "é"]),
    volumeOrdinals: ["the_tower": generator.int(in: 0...3), "the_sea": generator.int(in: 0...3), "é": 1],
    reachedMilestones: keys((0..<generator.int(in: 0...3)).map { _ in generator.pick(from: ["lamp_rank_4", "lamp_rank_5", "é"]) })
  )
}

private func reordered(_ value: OrderedJSON, _ generator: inout SeededGenerator) -> OrderedJSON {
  switch value {
  case .array(let items):
    return .array(items.map { reordered($0, &generator) })
  case .object(let object):
    let pairs = object.entries.map { (key: $0.key, value: reordered($0.value, &generator)) }
    return .object(OrderedJSONObject(generator.shuffled(pairs)))
  default:
    return value
  }
}

struct RevealPropertyTests {
  @Test func shouldValidateArbitraryJSONWithoutCrashingAndAgreeWithIsUnlockCondition() throws {
    try forAll(iterations: 600) { generator in
      let value = randomJSON(&generator, depth: 3)
      let messages = validateUnlockCondition(value)
      #expect(isUnlockCondition(value) == messages.isEmpty)
      #expect((UnlockCondition(validating: value) != nil) == messages.isEmpty)
    }
  }

  @Test func shouldParseArbitraryJSONAsAContractWithoutCrashing() throws {
    try forAll(iterations: 600) { generator in
      let value = randomJSON(&generator, depth: 3)
      if let contract = parseKnowledgeContract(value) { #expect(!contract.pov.isEmpty && contract.pov.allSatisfy { !$0.isEmpty }) }
      #expect(learnedFactKeys(value).count == Set(learnedFactKeys(value).map { JSString($0) }).count)
    }
  }

  @Test func shouldEvaluateEveryConditionThatValidatesWithoutErrorAndReportExactlyTheMissingTerms() throws {
    try forAll(iterations: 400) { generator in
      let terms = (0..<generator.int(in: 1...4)).map { _ in randomTerm(&generator) }
      let value = object(("all", .array(terms.map(json))))
      let condition = try #require(UnlockCondition(validating: value))
      #expect(condition.all == terms)

      let result = evaluateUnlock(condition, randomContext(&generator))
      #expect(result.holds == result.missing.isEmpty)
      #expect(result.missing.allSatisfy { missing in terms.contains(missing) })
    }
  }

  @Test func shouldKeepValidityAndTheSetOfMessagesWhenKeysAreReorderedWhereOnlyTheMessageOrderMayChange() throws {
    try forAll(iterations: 400) { generator in
      let value = randomJSON(&generator, depth: 3)
      let shuffled = reordered(value, &generator)
      #expect(validateUnlockCondition(value).jsSorted() == validateUnlockCondition(shuffled).jsSorted())
      #expect(parseKnowledgeContract(value) == parseKnowledgeContract(shuffled))
    }
  }

  @Test func shouldEvaluateAValidConditionTheSameWhateverTheKeyOrderOfItsJSON() throws {
    try forAll(iterations: 300) { generator in
      let terms = (0..<generator.int(in: 1...4)).map { _ in randomTerm(&generator) }
      let value = object(("all", .array(terms.map(json))))
      let context = randomContext(&generator)
      let original = try #require(UnlockCondition(validating: value))
      let shuffled = try #require(UnlockCondition(validating: reordered(value, &generator)))
      #expect(evaluateUnlock(original, context) == evaluateUnlock(shuffled, context))
    }
  }
}

struct UnlockConditionJSONTests {
  @Test func shouldListIntegerLikeKeysFirstInAscendingOrderAsAnObjectDoes() {
    let value = object(("b", .null), ("10", .null), ("a", .null), ("2", .null), ("all", .array([])))

    #expect(
      sameStrings(
        validateUnlockCondition(value),
        ["unlock has unexpected field '2'", "unlock has unexpected field '10'", "unlock has unexpected field 'b'", "unlock has unexpected field 'a'"]))
  }

  @Test func shouldRejectATermWhoseKeyIsNullAsTheReferenceDoes() {
    let value = object(("all", .array([object(("milestone", .null))])))

    #expect(validateUnlockCondition(value) == ["unlock.all[0].milestone must be a non-empty key"])
  }

  @Test func shouldTrimJavaScriptWhitespaceWhenJudgingAKeyEmpty() {
    for blank in ["\u{a0}", "\u{feff}", "\u{2003}", " \u{3000} "] {
      #expect(validateUnlockCondition(object(("all", .array([object(("volume", .string(blank)))])))) == ["unlock.all[0].volume must be a non-empty key"])
    }
    #expect(validateUnlockCondition(object(("all", .array([object(("volume", .string("\u{200b}")))])))).isEmpty)
  }

  @Test func shouldTreatTheUnlockConditionAsJSONValueBothWays() throws {
    let condition = UnlockCondition(all: [.milestone("a"), .volume("b"), .chapter(3), .ending])
    let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(condition))

    #expect(value == condition.jsonValue)
    #expect(try UnlockCondition(validating: value) == condition)
    #expect(try JSONDecoder().decode(UnlockCondition.self, from: JSONEncoder().encode(value)) == condition)
  }

  @Test func shouldThrowTheValidationMessagesWhenAJSONValueIsNotAnUnlockCondition() {
    #expect(throws: UnlockConditionError.invalid(["unlock.all must be a non-empty array"])) { try UnlockCondition(validating: JSONValue.object([:])) }
  }
}
