import Testing

@testable import NovelForgeCore

struct PromptDeviationTests {
  private static let disabled = PromptFixture.path("deviations", "disabledLookups").pStrings

  private static func adapted(_ text: String) -> String {
    PromptFixture.path("deviations", "replacements").pItems.reduce(text) { $0.jsSplit($1.pField("from").pText).joined(separator: $1.pField("to").pText) }
  }

  @Test func shouldDifferFromTheReferenceGuidanceOnlyByTheThreeLookupEdits() {
    let replacements = PromptFixture.path("deviations", "replacements").pItems
    #expect(replacements.count == 3)
    #expect(replacements.allSatisfy { PromptFixture.path("deviations", "rawGuidance").pText.jsSplit($0.pField("from").pText).count == 2 })
    #expect(sameText(Self.adapted(PromptFixture.path("deviations", "rawGuidance").pText), hubGuidance))
    #expect(sameText(Self.adapted(PromptFixture.path("deviations", "rawInstructions").pText), hubInstructions))
  }

  @Test func shouldNameNoLookupThisBuildDoesNotOffer() {
    let texts = [chatRefineSystem, hubGuidance, hubInstructions, chatScopeInstructions([]), chatCompactSystem, chatTitleSystem]
    for text in texts { for name in Self.disabled { #expect(!text.jsIncludes(name), "\(name)") } }
  }

  @Test func shouldKeepWebResearchOutOfEveryText() {
    let texts = [chatRefineSystem, hubInstructions, chatScopeInstructions([])]
    for text in texts {
      #expect(!text.jsIncludes("Web research"))
      #expect(!text.jsIncludes("untrusted reference material"))
    }
  }

  @Test func shouldNotChangeAnyTextWithTheContentMode() {
    #expect(!chatRefineSystem.jsToLowerCase().jsIncludes("unrestricted"))
    #expect(!hubGuidance.jsToLowerCase().jsIncludes("unrestricted"))
    #expect(PromptFixture.cases("turnRules").allSatisfy { !$0.pField("text").pText.jsToLowerCase().jsIncludes("unrestricted") })
  }
}
