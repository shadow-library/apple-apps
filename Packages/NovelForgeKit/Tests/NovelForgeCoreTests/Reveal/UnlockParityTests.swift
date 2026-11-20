import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

private struct ValidationCase: Decodable {
  let input: OrderedJSON
  let messages: [String]
  let valid: Bool

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    input = try container.decode(FixtureJSON.self).value
    messages = try container.decode([String].self)
    valid = try container.decode(Bool.self)
  }
}

private struct EvaluationCase: Decodable {
  let condition: UnlockCondition
  let context: UnlockContext
  let holds: Bool
  let missing: [UnlockTerm]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    condition = UnlockCondition(all: try container.decode([UnlockTerm].self))
    context = try container.decode(FixtureContext.self).context
    holds = try container.decode(Bool.self)
    missing = try container.decode([UnlockTerm].self)
  }
}

private struct DescriptionCase: Decodable {
  let term: UnlockTerm
  let text: String

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    term = try container.decode(UnlockTerm.self)
    text = try container.decode(String.self)
  }
}

private struct UnlockFixture: Decodable {
  let validation: [ValidationCase]
  let evaluation: [EvaluationCase]
  let descriptions: [DescriptionCase]
}

struct UnlockParityTests {
  private static func load() throws -> UnlockFixture {
    try ReferenceFixture.decode(UnlockFixture.self, from: "reveal/unlock.json")
  }

  @Test func shouldCarryAtLeastThreeHundredCasesPerFunction() throws {
    let fixture = try Self.load()
    #expect(fixture.validation.count >= 300)
    #expect(fixture.evaluation.count >= 300)
    #expect(fixture.descriptions.count >= 300)
    #expect(Set(fixture.validation.flatMap(\.messages)).count >= 40)
    #expect(fixture.validation.contains { $0.valid } && fixture.validation.contains { !$0.valid })
  }

  @Test func shouldReturnTheReferenceValidationMessagesInTheReferenceOrder() throws {
    let mismatches = try Self.load().validation.enumerated().filter { !sameStrings(validateUnlockCondition($1.input), $1.messages) }.map(\.offset)
    #expect(mismatches.isEmpty, "messages differ for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldAgreeWithTheReferenceOnWhetherAValueIsAnUnlockCondition() throws {
    let mismatches = try Self.load().validation.enumerated().filter { isUnlockCondition($1.input) != $1.valid }.map(\.offset)
    #expect(mismatches.isEmpty, "validity differs for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldBuildATypedConditionExactlyForTheValuesTheReferenceAccepts() throws {
    let mismatches = try Self.load().validation.enumerated().filter { (UnlockCondition(validating: $1.input) != nil) != $1.valid }.map(\.offset)
    #expect(mismatches.isEmpty, "typed condition differs for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldEvaluateEveryFixtureConditionAsTheReferenceDoes() throws {
    let mismatches = try Self.load().evaluation.enumerated().filter { _, reference in
      let result = evaluateUnlock(reference.condition, reference.context)
      return result.holds != reference.holds || result.missing != reference.missing
    }.map(\.offset)
    #expect(mismatches.isEmpty, "evaluation differs for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }

  @Test func shouldDescribeEveryFixtureTermWithTheReferenceWording() throws {
    let mismatches = try Self.load().descriptions.enumerated().filter { !describeUnlockTerm($1.term).jsEquals($1.text) }.map(\.offset)
    #expect(mismatches.isEmpty, "description differs for cases \(mismatches.prefix(10)) of \(mismatches.count)")
  }
}
