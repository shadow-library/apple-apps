import Foundation
import Testing

@testable import NovelForgeCore

struct PipelineOutputDecodingTests {
  private static func sample(_ key: String, _ name: String) -> OrderedJSON {
    PipelinePromptFixture.path("schemas", key, "samples").pItems.first { $0.pField("name").pText == name }?.pField("value") ?? .null
  }

  private static func data(_ key: String, _ name: String) -> Data { Data(sample(key, name).jsonText.utf8) }

  private static func validSamples(_ key: String) -> [OrderedJSON] {
    PipelinePromptFixture.path("schemas", key, "samples").pItems.filter { $0.pField("schemaValid").pFlag }
  }

  @Test func shouldDecodeEverySchemaValidSampleOfEachOutput() throws {
    for sample in Self.validSamples("continuity") { _ = try ContinuityOutput(data: Data(sample.pField("value").jsonText.utf8)) }
    for sample in Self.validSamples("review") { _ = try EditorialReviewOutput(data: Data(sample.pField("value").jsonText.utf8)) }
    for sample in Self.validSamples("chapterPlan") { #expect(PlannedChapter(json: sample.pField("value")) != nil, "\(sample.pField("name").pText)") }
    for sample in Self.validSamples("chapterSummarize") { #expect(ChapterSummarizeOutput(json: sample.pField("value")) != nil, "\(sample.pField("name").pText)") }
  }

  @Test func shouldReadAFullChapterPlan() throws {
    let plan = try #require(PlannedChapter(json: Self.sample("chapterPlan", "full")))
    #expect(plan.title == "The Stalled Ferry")
    #expect(plan.scenes.count == 1 && plan.scenes[0].pov == "mara" && plan.scenes[0].estimatedWords == 700)
    #expect(plan.continuesIntoNextChapter && plan.startsFromPreviousChapter && plan.handoffBeat == "mid-swing")
    #expect(plan.endingContract.hookType == .cliffhanger && plan.endingContract.mustNotResolve == ["thread:letter_sender"])
    #expect(plan.knowledgeContract?.pov == ["mara"] && plan.knowledgeContract?.learns?.first?.factKey == "lamp_origin")
    #expect(plan.claimedMilestones == ["first_light"] && plan.readerValue == ["new_information"] && plan.repetitionRisks == ["another crossing"])
    #expect(plan.densityRisk == "thin material" && plan.moves == "thread:letter_sender")
  }

  @Test func shouldDefaultTheContinuationFlagsAndLeaveOptionalPartsOut() throws {
    let plan = try #require(PlannedChapter(json: Self.sample("chapterPlan", "minimal")))
    #expect(!plan.continuesIntoNextChapter && !plan.startsFromPreviousChapter)
    #expect(plan.handoffBeat == nil && plan.knowledgeContract == nil && plan.claimedMilestones == nil && plan.densityRisk == nil && plan.moves == nil)
    #expect(PlannedChapter(json: Self.sample("chapterPlan", "scene-without-pov"))?.scenes.first?.pov == nil)
  }

  @Test func shouldReportThePlanIssuesTheReferenceReports() throws {
    for name in ["unknown-reader-value", "mixed-reader-value", "continues-without-handoff", "continues-blank-handoff", "starts-without-handoff", "starts-with-handoff", "minimal"] {
      let plan = try #require(PlannedChapter(json: Self.sample("chapterPlan", name)))
      let expected = PipelinePromptFixture.path("schemas", "chapterPlan", "samples").pItems.first { $0.pField("name").pText == name }?.pField("reviewIssues").pStrings
      #expect(chapterPlanIssues(plan) == expected, "\(name)")
    }
  }

  @Test func shouldNameTheKeyThatBreaksThePattern() throws {
    let plan = try #require(PlannedChapter(json: Self.sample("chapterPlan", "knowledge-uppercase-key")))
    #expect(chapterPlanKeyIssues(plan) == ["/knowledgeContract/learns/0/entityKey must match pattern \"^[a-z0-9_]+$\""])
    let digits = try #require(PlannedChapter(json: Self.sample("chapterPlan", "knowledge-digits-key")))
    #expect(chapterPlanKeyIssues(digits).isEmpty)
  }

  @Test func shouldMapAContinuityExtractionOntoTheFinalizeReviewMaterial() throws {
    let extraction = try ContinuityOutput(data: Self.data("continuity", "full")).finalizeExtraction
    #expect(extraction.appeared == ["mara", "kai"])
    #expect(extraction.chapterSummary == "They crossed and the lamp was lit.")
    #expect(extraction.newEntities.map(\.entityKey) == ["ferryman"] && extraction.newEntities.first?.type == .character && extraction.newEntities.first?.notes == "gruff")
    #expect(extraction.threads.count == 1 && extraction.threads[0].value.threadKey == "letter_sender" && extraction.threads[0].confidence == .low)
    #expect(extraction.threads[0].value.intentionallyOpen == true)
    #expect(extraction.mysteries[0].value.truthFactKey == "lamp_made" && extraction.mysteries[0].confidence == .high)
    #expect(extraction.relationships[0].value.evidence == "“Hold on,” she said." && extraction.relationships[0].confidence == .low)
    #expect(extraction.characterStates[0].value.conditions == ["tired"] && extraction.characterStates[0].value.immediateGoal == "wait")
    #expect(extraction.relationships[0].value.note == "warming")
    #expect(extraction.characterStates[0].value.statusNote == "hopeful" && extraction.characterStates[0].value.location == "the lamp room")
    #expect(extraction.mysteries[0].value.question == "where from?" && extraction.mysteries[0].value.intentionallyOpen == false)
    #expect(extraction.knowledgeChanges.first?.how == "read it in the letter")
    #expect(extraction.milestones.map(\.milestoneKey) == ["first_light"] && extraction.milestones[0].reached && extraction.milestones[0].evidence == "the lamp caught")
  }

  @Test func shouldLeaveAnAbsentIntentionallyOpenUnset() throws {
    let json = """
      {"appeared":[],"newEntities":[],"threads":[{"threadKey":"t","status":"open"}],"mysteries":[{"mysteryKey":"m","status":"open"}],"timeline":[],"relationships":[],\
      "power":[],"characterStates":[],"knowledgeChanges":[],"chapterSummary":"x"}
      """
    let extraction = try ContinuityOutput(data: Data(json.utf8)).finalizeExtraction
    #expect(extraction.threads[0].value.intentionallyOpen == nil && extraction.mysteries[0].value.intentionallyOpen == nil)
  }

  @Test func shouldMapAnEmptyContinuityExtractionToEmptyLists() throws {
    let extraction = try ContinuityOutput(data: Self.data("continuity", "empty")).finalizeExtraction
    #expect(extraction.appeared.isEmpty && extraction.newEntities.isEmpty && extraction.threads.isEmpty && extraction.mysteries.isEmpty)
    #expect(extraction.relationships.isEmpty && extraction.characterStates.isEmpty && extraction.knowledgeChanges.isEmpty && extraction.milestones.isEmpty)
    #expect(extraction.chapterSummary == "Mara lit the lamp.")
  }

  @Test func shouldRefuseAContinuityAnswerOutsideTheSchema() {
    #expect(throws: DecodingError.self) { try ContinuityOutput(data: Self.data("continuity", "bad-entity-type")) }
    #expect(throws: DecodingError.self) { try ContinuityOutput(data: Self.data("continuity", "bad-confidence")) }
  }

  @Test func shouldReadAnEditorialReview() throws {
    let review = try EditorialReviewOutput(data: Self.data("review", "revision"))
    #expect(review.disposition == .revisionRequested && review.note == "Tighten the ending.")
    #expect(review.findings == [.init(severity: .blocking, text: "The ending contradicts the brief.", evidence: "Mara walked away.")])
    #expect(review.proofreading == [.init(kind: .grammar, quote: "she go to the pier", fix: "she went to the pier", reason: "tense")])
    #expect(try EditorialReviewOutput(data: Self.data("review", "approve")).findings == nil)
  }

  @Test func shouldListEveryProofreadingKindTheSchemaNames() {
    let kinds = PipelinePromptFixture.path("schemas", "review", "schema", "properties", "proofreading", "items", "properties", "kind", "enum").pStrings
    #expect(EditorialReviewOutput.SlipKind.allCases.map(\.rawValue) == kinds)
  }

  @Test func shouldKeepTheSummaryAndTheRawContinuationState() throws {
    let output = try #require(ChapterSummarizeOutput(json: Self.sample("chapterSummarize", "full")))
    #expect(output.summary == "Mara lit the lamp.")
    #expect(output.state["lastBeat"]?.stringValue == "Mara lit the lamp")
    #expect(output.state["characterPositions"]?.arrayValue?.count == 1)
    #expect(ChapterSummarizeOutput(json: Self.sample("chapterSummarize", "missing-state")) == nil)
  }
}
