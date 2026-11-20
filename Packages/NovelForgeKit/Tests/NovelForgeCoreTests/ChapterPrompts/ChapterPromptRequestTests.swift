import ShadowAI
import ShadowCore
import ShadowText
import Testing

@testable import NovelForgeCore

struct ChapterPromptRequestTests {
  private let stable = String(repeating: "The lamp room kept its slow count of ships. ", count: 200)

  private func generation() -> ChapterPromptRequest {
    chapterGenerationRequest(
      ChapterGenerationInput(stableContext: stable, volatileContext: "volatile", chapterBrief: "brief", endingContract: "", guidance: ""),
      target: ResolvedWordTarget(min: 1800, max: 2600, aim: 2200))
  }

  @Test func shouldEndTheStablePrefixOnTheContextForGeneration() throws {
    let request = try generation().modelRequest(model: "m", maxOutputTokens: 4096).validated()
    #expect(request.system.map(\.endsStablePrefix) == [false, true])
    #expect(request.system[1].text == stable)
    #expect(request.messages == [.user("volatile\n\nChapter brief:\nbrief\n\n## ENDING CONTRACT\n\n\nAdditional guidance: ")])
    #expect(request.format == .text)
    #expect(!request.cachesConversation)
  }

  @Test func shouldEndTheStablePrefixOnTheContextForExpandAndRevision() throws {
    let expand = chapterExpandRequest(
      ChapterExpandInput(
        stableContext: stable, volatileContext: "v", chapterBrief: "b", endingContract: "", guidance: "", draftBody: "draft", draftWords: 5, minWords: 10, aimWords: 12,
        missingWords: 7))
    let revision = chapterRevisionRequest(contextPack: stable, chapterBrief: "b", draftBody: "draft", feedback: "f")
    for request in [expand, revision] {
      let mapped = try request.modelRequest(model: "m", maxOutputTokens: 4096, effort: .high).validated()
      #expect(mapped.system.map(\.endsStablePrefix) == [false, true])
      #expect(mapped.system[1].text == stable)
      #expect(mapped.messages.count == 1)
      #expect(mapped.effort == .high)
    }
  }

  @Test func shouldKeepTheFixOrderAndCacheTheContextMessage() throws {
    let request = try chapterFixRequest(contextPack: stable, prose: "prose", findings: "[hard] x").modelRequest(model: "m", maxOutputTokens: 4096).validated()
    #expect(request.system == [ContextSegment(text: chapterFixSystem)])
    #expect(request.messages.dropLast(2).map(\.text) == chapterFixFewShots.map(\.text))
    #expect(request.messages.dropLast().last == .user(stable))
    #expect(request.messages.last == .user("Draft to repair:\nprose\n\nFindings:\n[hard] x"))
    #expect(request.cachesConversation)
    #expect(request.format == .text)
  }

  @Test func shouldHoistTheJudgeSystemMessageAndAskForJSON() throws {
    let request = try chapterJudgeRequest(contextPack: stable, evaluation: "evaluate").modelRequest(model: "m", maxOutputTokens: 4096).validated()
    #expect(request.system == [ContextSegment(text: chapterJudgeSystem)])
    #expect(request.messages.count == chapterJudgeFewShots.count + 2)
    #expect(request.messages.prefix(chapterJudgeFewShots.count).map(\.text) == chapterJudgeFewShots.map(\.text))
    #expect(request.messages.dropLast().last == .user("Context:\n\(stable)"))
    #expect(request.messages.last == .user("---\nevaluate"))
    #expect(request.cachesConversation)
    #expect(request.format == .json(name: "judge", schema: JSONValue(schema: chapterJudgeResponseSchema)))
  }

  @Test func shouldAlternateTheFewShotRolesInTheConversation() throws {
    let request = try chapterJudgeRequest(contextPack: "c", evaluation: "e").modelRequest(model: "m", maxOutputTokens: 1).validated()
    #expect(request.messages.prefix(chapterJudgeFewShots.count).enumerated().allSatisfy { $0.element.role == ($0.offset.isMultiple(of: 2) ? .user : .assistant) })
  }

  @Test func shouldRefuseABlankStableContext() {
    let request = chapterRevisionRequest(contextPack: "  ", chapterBrief: "b", draftBody: "d", feedback: "f")
    #expect(throws: ModelError.self) { try request.modelRequest(model: "m", maxOutputTokens: 1).validated() }
  }

  @Test func shouldSpendAtMostFourBreakpointsAndSkipThoseBeforeTheThreshold() {
    let messages = (0..<8).map { PromptMessage($0.isMultiple(of: 2) ? .user : .assistant, String(repeating: "word ", count: 400)) }
    #expect(ChapterPromptRequest(messages, layout: .stablePrefix, breakpointsAt: [0, 1, 2, 3, 4, 5, 6, 7]).cacheBreakpoints == [4, 5, 6, 7])
    #expect(ChapterPromptRequest(messages, layout: .stablePrefix, breakpointsAt: [0, 1, 2, 99, -1]).cacheBreakpoints == [2])
    #expect(ChapterPromptRequest([PromptMessage(.system, "short")], layout: .stablePrefix, breakpointsAt: [0]).cacheBreakpoints == [])
  }
}
