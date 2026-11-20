import ShadowText
import Testing

@testable import NovelForgeCore

struct PipelinePromptSnapshotTests {
  @Test func shouldMatchTheSystemPromptsAndVersions() {
    let constants = PipelinePromptFixture.path("constants")
    #expect(sameText(chapterPlanSystem, constants.pField("plan").pField("system").pText))
    #expect(chapterPlanVersion == constants.pField("plan").pField("version").pText)
    #expect(sameText(continuitySystem, constants.pField("continuity").pField("system").pText))
    #expect(continuityVersion == constants.pField("continuity").pField("version").pText)
    #expect(sameText(continuityIsolatedNote, constants.pField("continuity").pField("isolatedNote").pText))
    #expect(sameText(canonRefreshSystem, constants.pField("canonRefresh").pField("system").pText))
    #expect(canonRefreshVersion == constants.pField("canonRefresh").pField("version").pText)
    #expect(canonRefreshOps.map(\.rawValue) == constants.pField("canonRefresh").pField("ops").pStrings)
    #expect(sameText(editorialReviewSystem, constants.pField("review").pField("system").pText))
    #expect(editorialReviewVersion == constants.pField("review").pField("version").pText)
    #expect(sameText(chapterSummarizeSystem, constants.pField("summarize").pField("system").pText))
    #expect(chapterSummarizeVersion == constants.pField("summarize").pField("version").pText)
  }

  @Test func shouldMatchThePlanConstantsTakenFromTheService() {
    let plan = PipelinePromptFixture.path("constants", "plan")
    #expect(sameText(chapterPlanNone, plan.pField("none").pText))
    #expect(sameText(chapterPlanEnding, plan.pField("ending").pText))
    #expect(sameText(chapterPlanNotEnding, plan.pField("notEnding").pText))
  }

  @Test func shouldNameNoLookupThisBuildDoesNotOffer() {
    let texts = [chapterPlanSystem, continuitySystem, canonRefreshSystem, editorialReviewSystem, chapterSummarizeSystem]
    for text in texts {
      for name in PromptFixture.path("deviations", "disabledLookups").pStrings { #expect(!text.jsIncludes(name), "\(name)") }
    }
  }

  @Test func shouldMatchEveryChapterPlanCase() {
    let cases = PipelinePromptFixture.cases("plan")
    #expect(cases.count == 35)
    for entry in cases {
      let input = entry.pField("input")
      let target = entry.pField("target")
      let resolved = ResolvedWordTarget(min: target.pField("min").numberValue ?? 0, max: target.pField("max").numberValue ?? 0, aim: target.pField("aim").numberValue ?? 0)
      let length = ChapterPlanLength(resolved)
      let vars = entry.pField("vars")
      #expect(length.min == vars.pField("wordTargetMin").pText && length.aim == vars.pField("wordTargetAim").pText, "\(entry.pField("name").pText)")
      #expect(length.max == vars.pField("wordTargetMax").pText && length.minScenes == vars.pField("minScenes").pText, "\(entry.pField("name").pText)")
      let none = chapterPlanNone
      let planInput = ChapterPlanInput(
        catalog: input.pField("catalog").pText, obligations: input.pField("obligations").pText, milestones: input.pField("milestones").pText,
        chapter: Int(input.pField("chapterNumber").pText) ?? 0, isEnding: input.pField("endingNote").pText == chapterPlanEnding, length: length,
        authorIntent: input.pField("authorIntent").pText == none ? nil : input.pField("authorIntent").pText,
        chosenDirection: input.pField("chosenDirection").pText == none ? nil : input.pField("chosenDirection").pText)
      #expect(samePipelineRequest(chapterPlanRequest(planInput), entry), "\(entry.pField("name").pText)")
      #expect(chapterPlanRequest(planInput).cacheBreakpoints.isEmpty)
    }
  }

  @Test func shouldMatchEveryContinuityCaseStandardAndIsolated() {
    let cases = PipelinePromptFixture.cases("continuity")
    #expect(cases.count == 4)
    for entry in cases {
      let pack = entry.pField("contextPack").pText
      let chapter = Int(entry.pField("chapterNumber").numberValue ?? 0)
      let prose = entry.pField("chapterProse").pText
      #expect(samePipelineRequest(continuityRequest(contextPack: pack, chapter: chapter, prose: prose), entry, key: "standard"), "\(entry.pField("name").pText)")
      #expect(sameText(continuityIsolatedContext(pack), entry.pField("isolatedPack").pText), "\(entry.pField("name").pText)")
      #expect(samePipelineRequest(continuityRequest(contextPack: pack, chapter: chapter, prose: prose, isolated: true), entry, key: "isolated"), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchTheContinuityRosterSlicedFromTheGraph() {
    let cases = PipelinePromptFixture.cases("roster")
    #expect(cases.count == 3)
    for entry in cases {
      let entities = entry.pField("entities").pItems.map {
        ContinuityRosterEntity(entityKey: $0.pField("entityKey").pText, name: $0.pField("name").pText, type: $0.pField("type").pText)
      }
      let threads = entry.pField("threads").pItems.map {
        ContinuityRosterThread(threadKey: $0.pField("threadKey").pText, status: $0.pField("status").pText, summary: $0.pField("summary").stringValue)
      }
      let mysteries = entry.pField("mysteries").pItems.map {
        ContinuityRosterMystery(mysteryKey: $0.pField("mysteryKey").pText, status: $0.pField("status").pText, question: $0.pField("question").stringValue)
      }
      #expect(sameText(continuityRoster(entities: entities, threads: threads, mysteries: mysteries), entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchTheMilestoneContextPackSlicedFromTheService() {
    let cases = PipelinePromptFixture.cases("milestonePack")
    #expect(cases.count == 4)
    for entry in cases {
      let rows = entry.pField("milestones").pItems.map {
        ContinuityMilestoneRow(milestoneKey: $0.pField("milestoneKey").pText, label: $0.pField("label").pText, state: $0.pField("state").pText)
      }
      let pack = continuityContextPack(roster: entry.pField("roster").pText, milestones: rows, claimed: entry.pField("claimed").pStrings)
      #expect(sameText(pack, entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryCanonRefreshCaseAndItsCacheBreakpoints() {
    let cases = PipelinePromptFixture.cases("canonRefresh")
    #expect(cases.count == 4)
    for entry in cases {
      let request = canonRefreshRequest(material: entry.pField("material").pText, chapterProse: entry.pField("chapterProse").pText)
      #expect(samePipelineRequest(request, entry), "\(entry.pField("name").pText)")
      #expect(request.cacheBreakpoints == breakpoints(entry), "\(entry.pField("name").pText)")
    }
    #expect(cases.contains { !breakpoints($0).isEmpty } && cases.contains { breakpoints($0).isEmpty })
  }

  @Test func shouldMatchTheEditorialChapterBriefSlicedFromTheService() {
    let cases = PipelinePromptFixture.cases("editorialBrief")
    #expect(cases.count == 5)
    for entry in cases {
      let plan = entry.pField("hasBrief").pFlag ? entry.pField("chapterBrief").pText : nil
      #expect(sameText(editorialChapterBrief(plan: plan, endingContract: entry.pField("endingContract").pText), entry.pField("text").pText), "\(entry.pField("name").pText)")
    }
  }

  @Test func shouldMatchEveryEditorialReviewCase() {
    let cases = PipelinePromptFixture.cases("review")
    #expect(cases.count == 4)
    for entry in cases {
      let request = editorialReviewRequest(
        contextPack: entry.pField("contextPack").pText, chapterBrief: entry.pField("chapterBrief").pText, draftBody: entry.pField("draftBody").pText,
        settledFindings: entry.pField("settledFindings").pText)
      #expect(samePipelineRequest(request, entry), "\(entry.pField("name").pText)")
      #expect(request.cacheBreakpoints.isEmpty)
    }
  }

  @Test func shouldMatchEveryChapterSummarizeCase() {
    let cases = PipelinePromptFixture.cases("summarize")
    #expect(cases.count == 4)
    for entry in cases { #expect(samePipelineRequest(chapterSummarizeRequest(chapterProse: entry.pField("chapterProse").pText), entry), "\(entry.pField("name").pText)") }
  }
}
