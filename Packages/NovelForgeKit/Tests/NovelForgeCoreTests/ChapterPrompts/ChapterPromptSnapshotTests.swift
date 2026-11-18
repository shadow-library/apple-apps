import ShadowAI
import ShadowCore
import Testing

@testable import NovelForgeCore

struct ChapterPromptSnapshotTests {
  private let constants = ChapterPromptFixture.path("constants")

  @Test func shouldMatchTheGenerationSystemForTheDefaultTarget() {
    let target = ResolvedWordTarget(min: 1800, max: 2600, aim: 2200)
    let expected = constants.pField("generation").pField("system").pText.replacing("{wordTargetMin}", with: "1,800").replacing("{wordTargetAim}", with: "2,200")
      .replacing("{wordTargetMax}", with: "2,600")
    #expect(sameText(chapterGenerationSystem(target), expected))
  }

  @Test func shouldMatchTheVersionsAndFixedTexts() {
    #expect(chapterGenerationVersion == constants.pField("generation").pField("version").pText)
    #expect(chapterExpandVersion == constants.pField("chapterExpand").pField("version").pText)
    #expect(chapterTitleVersion == constants.pField("title").pField("version").pText)
    #expect(chapterFixVersion == constants.pField("fix").pField("version").pText)
    #expect(chapterRevisionVersion == constants.pField("revision").pField("version").pText)
    #expect(chapterJudgeVersion == constants.pField("judge").pField("version").pText)
    #expect(sameText(chapterExpandSystem, constants.pField("chapterExpand").pField("system").pText))
    #expect(sameText(chapterTitleSystem, constants.pField("title").pField("system").pText))
    #expect(sameText(chapterFixSystem, constants.pField("fix").pField("system").pText))
    #expect(sameText(chapterRevisionSystem, constants.pField("revision").pField("system").pText))
    #expect(sameText(chapterJudgeSystem, constants.pField("judge").pField("system").pText))
    #expect(ChapterPromptRequest.minCacheableTokens == Int(constants.pField("minCacheableTokens").pNumber))
  }

  @Test func shouldMatchTheFewShotExamples() {
    #expect(sameMessages(chapterFixFewShots, constants.pField("fix").pField("fewShots").pMessages))
    #expect(sameMessages(chapterJudgeFewShots, constants.pField("judge").pField("fewShots").pMessages))
    #expect(chapterJudgeFewShots.count == 18)
  }

  @Test func shouldMatchEveryGenerationRequest() {
    let cases = ChapterPromptFixture.cases("generation")
    #expect(cases.count == 24)
    for entry in cases {
      let input = entry.pField("input")
      let target = entry.pField("target")
      let request = chapterGenerationRequest(
        ChapterGenerationInput(
          stableContext: input.pField("stableContext").pText, volatileContext: input.pField("volatileContext").pText, chapterBrief: input.pField("chapterBrief").pText,
          endingContract: input.pField("endingContract").pText, guidance: input.pField("guidance").pText),
        target: ResolvedWordTarget(min: target.pField("min").pNumber, max: target.pField("max").pNumber, aim: target.pField("aim").pNumber))
      #expect(sameRequest(request, entry), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldRenderWordTargetsLikeToLocaleString() {
    let cases = ChapterPromptFixture.cases("wordCases")
    #expect(cases.count == 15)
    for entry in cases { #expect(entry.pField("value").pNumber.enUSGrouped == entry.pField("text").pText, "\(entry.pField("value"))") }
  }

  @Test func shouldMatchEveryExpandRequest() {
    let cases = ChapterPromptFixture.cases("chapterExpand")
    #expect(cases.count == 4)
    for entry in cases {
      let request = chapterExpandRequest(
        ChapterExpandInput(
          stableContext: entry.pField("stableContext").pText, volatileContext: entry.pField("volatileContext").pText, chapterBrief: entry.pField("chapterBrief").pText,
          endingContract: entry.pField("endingContract").pText, guidance: entry.pField("guidance").pText, draftBody: entry.pField("draftBody").pText,
          draftWords: entry.pField("draftWords").pNumber, minWords: entry.pField("minWords").pNumber, aimWords: entry.pField("aimWords").pNumber,
          missingWords: entry.pField("missingWords").pNumber))
      #expect(sameRequest(request, entry), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryTitleRequest() {
    let cases = ChapterPromptFixture.cases("title")
    #expect(cases.count == 3)
    for entry in cases {
      let messages = chapterTitleMessages(existingTitles: entry.pField("existingTitles").pText, chapterSummary: entry.pField("chapterSummary").pText)
      #expect(sameMessages(messages, entry.pField("messages").pMessages), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryFixRequest() {
    let cases = ChapterPromptFixture.cases("fix")
    #expect(cases.count == 3)
    for entry in cases {
      let request = chapterFixRequest(contextPack: entry.pField("contextPack").pText, prose: entry.pField("prose").pText, findings: entry.pField("findings").pText)
      #expect(sameRequest(request, entry), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryRevisionRequest() {
    let cases = ChapterPromptFixture.cases("revision")
    #expect(cases.count == 2)
    for entry in cases {
      let request = chapterRevisionRequest(
        contextPack: entry.pField("contextPack").pText, chapterBrief: entry.pField("chapterBrief").pText, draftBody: entry.pField("draftBody").pText,
        feedback: entry.pField("feedback").pText)
      #expect(sameRequest(request, entry), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryJudgeRequestWithoutTools() {
    let cases = ChapterPromptFixture.cases("judge")
    #expect(cases.count == 4)
    for entry in cases {
      let request = chapterJudgeRequest(contextPack: entry.pField("contextPack").pText, evaluation: entry.pField("evaluation").pText)
      let expected = entry.pField("messages").pItems
      #expect(sameMessages(request.messages, entry.pField("messages").pMessages), "\(entry.pField("name").pText)")
      #expect(request.cacheBreakpoints == expected.indices.filter { expected[$0].pField("cached").pFlag }, "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldPutTheJudgeSystemMessageAfterItsExamples() {
    let request = chapterJudgeRequest(contextPack: "pack", evaluation: "task")
    #expect(request.messages.prefix(18).allSatisfy { $0.role != .system })
    #expect(request.messages[18].role == .system)
    #expect(request.cacheBreakpoints == [18, 19, 20])
  }

  @Test func shouldMatchEveryJudgeEvaluation() {
    let cases = ChapterPromptFixture.cases("evaluations")
    #expect(cases.count == 6)
    for entry in cases {
      let brief = entry.pField("brief")
      let contract = brief.pField("endingContract")
      let input = ChapterJudgeEvaluationInput(
        prose: entry.pField("prose").pText, pov: brief.pField("pov").stringValue, briefBody: brief.pField("body").stringValue,
        endingContract: contract.objectValue == nil ? nil : endingContract(contract), hiddenFacts: facts(entry.pField("hidden"), used: entry.pField("viewUsed").pFlag),
        readerKnows: facts(entry.pField("readerKnows"), used: entry.pField("viewUsed").pFlag), readabilityEvidence: entry.pField("readabilityEvidence").pText)
      #expect(sameText(chapterJudgeEvaluation(input), entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMarkTheCachePrefixOnlyOnceItReachesTheThreshold() {
    let cases = ChapterPromptFixture.cases("thresholdCases")
    #expect(cases.map { $0.pField("breakpoints").pBreakpoints } == [[], [], [1], [1]])
    for entry in cases {
      let request = chapterExpandRequest(
        ChapterExpandInput(
          stableContext: entry.pField("stableContext").pText, volatileContext: entry.pField("volatileContext").pText, chapterBrief: entry.pField("chapterBrief").pText,
          endingContract: entry.pField("endingContract").pText, guidance: entry.pField("guidance").pText, draftBody: entry.pField("draftBody").pText,
          draftWords: entry.pField("draftWords").pNumber, minWords: entry.pField("minWords").pNumber, aimWords: entry.pField("aimWords").pNumber,
          missingWords: entry.pField("missingWords").pNumber))
      #expect(sameRequest(request, entry), "\(entry.pField("target"))")
    }
  }

  @Test func shouldRenderTheEndingContract() {
    let cases = ChapterPromptFixture.cases("renderEndingContract")
    #expect(cases.count == 6)
    for entry in cases {
      let value = endingContract(entry.pField("contract"))
      let notes: [JSString: String?]? = entry.pField("notes").arrayValue.map { pairs in
        Dictionary(pairs.map { (JSString($0.pItems[0].pText), $0.pItems[1].stringValue) }) { _, last in last }
      }
      #expect(sameText(renderEndingContract(value, factWriterNotes: notes), entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldRenderNothingWithoutAnEndingContract() {
    #expect(renderEndingContract(nil) == "")
    #expect(sameText(constants.pField("hiddenThreadPlaceholder").pText, "keep the hidden thread unresolved"))
  }

  private func endingContract(_ contract: OrderedJSON) -> ChapterEndingContract {
    ChapterEndingContract(
      hookType: StoredEnum<HookType>(rawValue: contract.pField("hookType").pText), emotionalBeat: contract.pField("emotionalBeat").pText,
      openQuestion: contract.pField("openQuestion").pText, handoffState: contract.pField("handoffState").pText,
      mustNotResolve: contract.pField("mustNotResolve").arrayValue.map { $0.map(\.pText) })
  }

  private func facts(_ list: OrderedJSON, used: Bool) -> [DisclosureFact] {
    guard used else { return [] }
    return list.pItems.map { DisclosureFact(factKey: $0.pField("factKey").pText, text: $0.pField("text").pText, source: FactSource(rawValue: $0.pField("source").pText)) }
  }
}
