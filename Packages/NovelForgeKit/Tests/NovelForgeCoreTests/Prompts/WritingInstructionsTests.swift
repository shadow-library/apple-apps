import ShadowText
import Testing

@testable import NovelForgeCore

struct WritingInstructionsTests {
  private static let cases = PromptFixture.path("writing", "resolved").pItems

  @Test func shouldMatchTheLegacyDefaults() {
    let expected = PromptFixture.path("constants", "legacyDefaults").pStrings
    #expect(expected.count == 4)
    #expect(legacyDefaultWritingInstructions.count == expected.count)
    #expect(zip(legacyDefaultWritingInstructions, expected).allSatisfy { sameText($0, $1) })
    #expect(sameText(projectAdditionsHeading, PromptFixture.path("constants", "projectAdditionsHeading").pText))
  }

  @Test func shouldResolveEveryStoredTextLikeTheReference() {
    #expect(Self.cases.count == 55)
    for (index, entry) in Self.cases.enumerated() {
      let stored: String? = entry.pField("stored").stringValue
      let result = resolveWritingInstructions(stored)
      let expected = entry.pField("result")
      #expect(
        result.additions.map { $0.jsEquals(expected.pField("additions").pText) && expected.pField("additions").stringValue != nil }
          ?? (expected.pField("additions").stringValue == nil), "case \(index)")
      #expect(result.removedDefaultCopy == expected.pField("removedDefaultCopy").pFlag, "case \(index)")
      #expect(writingInstructionAdditions(stored) == result.additions, "case \(index)")
    }
  }

  @Test func shouldExerciseEveryBranch() {
    let results = Self.cases.map { $0.pField("result") }
    #expect(results.contains { $0.pField("removedDefaultCopy").pFlag && $0.pField("additions").stringValue != nil })
    #expect(results.contains { $0.pField("removedDefaultCopy").pFlag && $0.pField("additions").stringValue == nil })
    #expect(results.contains { !$0.pField("removedDefaultCopy").pFlag && $0.pField("additions").stringValue != nil })
    #expect(results.contains { !$0.pField("removedDefaultCopy").pFlag && $0.pField("additions").stringValue == nil })
  }

  @Test func shouldTreatAnEmptyStoredTextAsNoRules() {
    #expect(resolveWritingInstructions(nil) == ResolvedWritingInstructions(additions: nil, removedDefaultCopy: false))
    #expect(resolveWritingInstructions("") == ResolvedWritingInstructions(additions: nil, removedDefaultCopy: false))
  }

  @Test func shouldLayerTheAdditionsAfterTheDefault() {
    for entry in PromptFixture.path("writing", "effective").pItems {
      let result = effectiveWritingInstructions(additions: entry.pField("additions").stringValue)
      #expect(sameText(result.text, entry.pField("result").pField("text").pText))
      #expect(result.truncated == entry.pField("result").pField("truncated").pFlag)
    }
  }

  @Test func shouldNeverCutTheDefaultWhenTheBudgetIsTight() {
    let additions = "First paragraph of rules.\n\nSecond paragraph of rules."
    let floor = effectiveWritingInstructions(additions: additions, maxTokens: 0)
    #expect(sameText(floor.text, defaultWritingInstructions) && floor.truncated)
    let room = countTokens("\(defaultWritingInstructions)\n\n\(projectAdditionsHeading)\n\n") + countTokens(additions) + 10
    let fitted = effectiveWritingInstructions(additions: additions, maxTokens: room)
    #expect(fitted.text.jsStartsWith(defaultWritingInstructions) && fitted.text.jsEndsWith(additions) && !fitted.truncated)
  }
}
