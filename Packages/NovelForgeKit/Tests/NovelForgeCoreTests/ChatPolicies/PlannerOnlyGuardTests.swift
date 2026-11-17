import Testing

@testable import NovelForgeCore

private func args(_ json: String) throws -> OrderedJSON { try OrderedJSON(parsing: json) }

struct PlannerOnlyGuardParityTests {
  private static let fixture = Result { try ChatFixture.load("planner-only.json") }

  @Test func shouldShareTheReferenceConstants() throws {
    let fixture = try Self.fixture.get()
    #expect(plannerOnlyWarning.jsEquals(try #require(fixture["warning"]).text))
    #expect(fixture["tools"]?.items.map(\.text) == [plannerOnlyLookupTool, authorNotesLookupTool])
  }

  @Test func shouldJudgeEveryLookupAsTheReference() throws {
    var reads = 0
    for (position, item) in try #require(try Self.fixture.get()["reads"]).items.enumerated() {
      let value = item["args"]?["value"]
      let verdict = readsPlannerOnlyPage(tool: try #require(item["tool"]).text, args: value)
      #expect(verdict == item["expected"]?.chatFlag, "read \(position)")
      if verdict { reads += 1 }
    }
    #expect(reads > 5)
  }

  @Test func shouldWarnOnEveryTurnAsTheReference() throws {
    for (position, item) in try #require(try Self.fixture.get()["turns"]).items.enumerated() {
      let warnings = try #require(item["warnings"]).items.map(\.text)
      let result = chatTurnWarnings(warnings, readPlannerOnly: item["read"]?.chatFlag == true)
      #expect(result == item["expected"]?.items.map(\.text), "turn \(position)")
    }
  }
}

// apps/novel-forge-server/tests/refinement/planner-only-guard.spec.ts:5
struct PlannerOnlyGuardSpecTests {
  @Test func shouldNoticeALookupThatReadTheOrganisedTimelineOrTheOpenQuestionsAndNoOtherPage() throws {
    #expect(readsPlannerOnlyPage(tool: "get_bible_document", args: try args(#"{"section":"project","slug":"timeline"}"#)))
    #expect(readsPlannerOnlyPage(tool: "get_bible_document", args: try args(#"{"section":"project","slug":"open-questions"}"#)))
    #expect(!readsPlannerOnlyPage(tool: "get_bible_document", args: try args(#"{"section":"world","slug":"timeline"}"#)))
    #expect(!readsPlannerOnlyPage(tool: "get_entity", args: try args(#"{"section":"project","slug":"timeline"}"#)))
    #expect(!readsPlannerOnlyPage(tool: "get_bible_document", args: try args("null")))
  }

  @Test func shouldTreatReadingTheAuthorsNotesAsAPlannerOnlyReadAndACanonFactLookupAsNone() throws {
    #expect(readsPlannerOnlyPage(tool: "get_notes", args: try args("{}")))
    #expect(readsPlannerOnlyPage(tool: "get_notes", args: nil))
    #expect(!readsPlannerOnlyPage(tool: "get_canon_facts", args: try args(#"{"keys":["keeper_bargain"]}"#)))
    #expect(plannerOnlyWarning.contains("your notes"))
  }

  @Test func shouldSayTheWarningHoldsWhatTheChapterWriterOrReadersCouldSee() {
    #expect(plannerOnlyWarning.contains("its changes to what the chapter writer or your readers could see wait for you"))
  }

  @Test func shouldWarnOnceOnATurnThatReadOneAndLeaveAnyOtherTurnsWarningsAsTheyAre() {
    #expect(chatTurnWarnings([], readPlannerOnly: true) == [plannerOnlyWarning])
    #expect(chatTurnWarnings(["echo"], readPlannerOnly: true) == ["echo", plannerOnlyWarning])
    #expect(chatTurnWarnings([plannerOnlyWarning], readPlannerOnly: true) == [plannerOnlyWarning])
    #expect(chatTurnWarnings(["echo"], readPlannerOnly: false) == ["echo"])
  }
}
