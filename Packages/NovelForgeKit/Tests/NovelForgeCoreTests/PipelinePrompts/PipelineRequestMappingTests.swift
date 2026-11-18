import ShadowAI
import Testing

@testable import NovelForgeCore

struct PipelineRequestMappingTests {
  private let stable = String(repeating: "The lamp room kept its slow count of ships. ", count: 200)

  @Test func shouldSendASimplePromptAsOneSystemSegmentAndOneUserMessage() throws {
    let request = try chapterSummarizeRequest(chapterProse: "Mara lit the lamp.").modelRequest(model: "m", maxOutputTokens: 512, effort: .high).validated()
    #expect(request.system == [ContextSegment(text: chapterSummarizeSystem)])
    #expect(request.messages == [.user("Chapter prose:\n\nMara lit the lamp.")])
    #expect(request.format == .text)
    #expect(!request.cachesConversation)
    #expect(request.effort == .high)
  }

  @Test func shouldEndTheStablePrefixOnTheCanonRefreshMaterial() throws {
    let request = try canonRefreshRequest(material: stable, chapterProse: "Mara lit the lamp.").modelRequest(model: "m", maxOutputTokens: 4096).validated()
    #expect(request.system.map(\.endsStablePrefix) == [false, true])
    #expect(request.system[0].text == canonRefreshSystem)
    #expect(request.system[1].text == stable)
    #expect(request.messages == [.user("Mara lit the lamp.\n\nList every page or record this chapter left out of date.")])
  }

  @Test func shouldMarkOnlyTheMaterialMessageWhenTheSystemPromptAloneIsBelowTheThreshold() {
    #expect(canonRefreshRequest(material: stable, chapterProse: "p").cacheBreakpoints == [1])
    #expect(canonRefreshRequest(material: "short", chapterProse: "p").cacheBreakpoints.isEmpty)
  }

  @Test func shouldSpendAtMostFourBreakpointsAndSkipThoseBeforeTheThreshold() {
    let messages = [PromptMessage(.system, stable)] + (0..<6).map { PromptMessage($0.isMultiple(of: 2) ? .user : .assistant, String(repeating: "word ", count: 400)) }
    let request = ChapterPromptRequest(messages, layout: .stablePrefix)
    #expect(request.cacheBreakpoints == [0, 1, 5])
    #expect(ChapterPromptRequest([PromptMessage(.system, "short"), PromptMessage(.user, "x")], layout: .stablePrefix).cacheBreakpoints.isEmpty)
  }

  @Test func shouldRefuseABlankMaterialSegment() {
    let request = canonRefreshRequest(material: "  ", chapterProse: "p")
    #expect(throws: ModelError.self) { try request.modelRequest(model: "m", maxOutputTokens: 1).validated() }
  }

  @Test func shouldSendThePlanAndContinuityPromptsWithoutBreakpoints() throws {
    let continuity = continuityRequest(contextPack: stable, chapter: 3, prose: "prose")
    #expect(continuity.cacheBreakpoints.isEmpty)
    let mapped = try continuity.modelRequest(model: "m", maxOutputTokens: 4096).validated()
    #expect(mapped.system == [ContextSegment(text: continuitySystem)])
    #expect(mapped.messages.count == 1)
  }

  @Test func shouldKeepEverySystemMessageAndTheAssistantTurnInThePlainLayout() {
    let messages = [PromptMessage(.system, "one"), PromptMessage(.system, "two"), PromptMessage(.user, "a"), PromptMessage(.assistant, "b"), PromptMessage(.user, "c")]
    let request = ChapterPromptRequest(messages, layout: .plain, breakpointsAt: []).modelRequest(model: "m", maxOutputTokens: 1)
    #expect(request.system == [ContextSegment(text: "one"), ContextSegment(text: "two")])
    #expect(request.messages == [.user("a"), .assistant("b"), .user("c")])
    #expect(!request.cachesConversation)
  }
}
