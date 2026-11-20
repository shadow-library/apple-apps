import ShadowText
import Testing

@testable import NovelForgeCore

private struct TurnOutput: ChatTurnOutput {
  var reply: String
  var changeSet: [OrderedJSONObject]?
  var question: OrderedJSON?

  func replacing(reply: String, changeSet: [OrderedJSONObject]?) -> TurnOutput {
    TurnOutput(reply: reply, changeSet: changeSet, question: question)
  }

  init(reply: String, changeSet: [OrderedJSONObject]? = nil, question: OrderedJSON? = nil) {
    self.reply = reply
    self.changeSet = changeSet
    self.question = question
  }

  init(json: OrderedJSON) {
    self.init(reply: json["reply"]?.text ?? "", changeSet: json["changeSet"]?.chatOpsIfPresent, question: json["question"])
  }

  var changeSetTexts: [String]? { changeSet?.map { OrderedJSON.object($0).jsonText } }
}

private func op(_ json: String) throws -> OrderedJSONObject { try #require(try OrderedJSON(parsing: json).objectValue) }

private func mode(_ text: String) -> RefinementChatMode { RefinementChatMode.allCases.first { $0.rawValue == text } ?? .manual }

private func routing(_ text: String) -> OrganiseRouting {
  switch text {
  case "card": .card
  case "start": .start
  default: .none
  }
}

struct LaterPlansGuardParityTests {
  private static let fixture = Result { try ChatFixture.load("later-plans.json") }

  @Test func shouldShareTheReferenceConstants() throws {
    let constants = try #require(try Self.fixture.get()["constants"])
    #expect(laterBandHeadings.jsEquals(try #require(constants["headings"]).text))
    #expect(organiseNotesOp == constants["organiseOp"]?.text)
    #expect(organiseRoutedNote.jsEquals(try #require(constants["routedNote"]).text))
    #expect(organiseCardNote.jsEquals(try #require(constants["cardNote"]).text))
    #expect(plansWithheldNote.jsEquals(try #require(constants["withheldNote"]).text))
  }

  @Test func shouldRecogniseEveryOpeningAsTheReference() throws {
    for item in try #require(try Self.fixture.get()["leads"]).items {
      let message = try #require(item["message"]).text
      #expect(isNotesOrganiseRequest(message) == item["expected"]?.chatFlag, "message \(message)")
    }
  }

  @Test func shouldRouteEveryCombinationAsTheReference() throws {
    for item in try #require(try Self.fixture.get()["routing"]).items {
      let result = organiseRouting(organiseRequest: item["request"]?.chatFlag == true, mode: mode(item["mode"]?.text ?? ""), justDiscussing: item["discussing"]?.chatFlag == true)
      #expect(result == routing(item["expected"]?.text ?? ""))
    }
  }

  @Test func shouldJudgeEveryPageAsTheReference() throws {
    var caught = 0
    for (position, item) in try #require(try Self.fixture.get()["pages"]).items.enumerated() {
      let fields = try #require(item["op"]?.objectValue)
      let verdict = writesPlansOnWriterPage(fields)
      #expect(verdict == item["expected"]?.chatFlag, "page \(position)")
      if verdict { caught += 1 }
    }
    #expect(caught > 20)
  }

  @Test func shouldListEveryIssueAsTheReference() throws {
    var issued = 0
    for (position, item) in try #require(try Self.fixture.get()["issues"]).items.enumerated() {
      let issues = laterPlanIssues(item["changeSet"]?.chatOpsIfPresent, organiseRequest: item["organiseRequest"]?.chatFlag == true)
      #expect(issues.count == item["expected"]?.items.count && zip(issues, item["expected"]?.items ?? []).allSatisfy { $0.jsEquals($1.text) }, "issues \(position)")
      issued += issues.count
    }
    #expect(issued > 20)
  }

  @Test func shouldStageEveryTurnAsTheReference() throws {
    var rewritten = 0
    for (position, item) in try #require(try Self.fixture.get()["staged"]).items.enumerated() {
      let output = TurnOutput(json: try #require(item["output"]))
      let expected = TurnOutput(json: try #require(item["expected"]))
      let staged = withLaterPlansRouted(output, organise: routing(item["mode"]?.text ?? ""))
      #expect(staged.reply.jsEquals(expected.reply) && staged.changeSetTexts == expected.changeSetTexts, "staged \(position)")
      #expect(staged.question.map { $0.jsonText } == expected.question.map { $0.jsonText }, "question \(position)")
      if !staged.reply.jsEquals(output.reply) { rewritten += 1 }
    }
    #expect(rewritten > 10)
  }
}

private let notesOpener =
  "Here are my notes for the story. Organise them into my Story Bible as the world stands when the story opens, and keep anything that happens later as my plans."
private let plansPage =
  ###"{"op":"bible_document.upsert","section":"plot","slug":"default","frontmatter":{"title":"Plans"},"body":"## The Café Treaty\n\nThey meet at noon."}"###
private let openingPage =
  ###"{"op":"bible_document.upsert","section":"world","slug":"default","frontmatter":{"title":"The World at Story Open"},"body":"## The evening\n\nA call."}"###
private let organise = #"{"op":"action.organise_notes"}"#

private func page(_ base: String, _ section: String? = nil, _ slug: String? = nil, title: String? = nil) throws -> OrderedJSONObject {
  var fields = try #require(try OrderedJSON(parsing: base).objectValue).entries.map { (key: $0.key, value: $0.value) }
  fields = fields.map { entry in
    switch entry.key {
    case "section": section.map { (key: "section", value: .string($0)) } ?? entry
    case "slug": slug.map { (key: "slug", value: .string($0)) } ?? entry
    case "frontmatter": title.map { (key: "frontmatter", value: .object(OrderedJSONObject([(key: "title", value: .string($0))]))) } ?? entry
    default: entry
    }
  }
  return OrderedJSONObject(fields)
}

// apps/novel-forge-server/tests/refinement/later-plans-guard.spec.ts:21
struct LaterPlansGuardSpecTests {
  @Test func shouldRecogniseTheNewNovelOpenerAndTheOpenerChipInEitherSpelling() {
    #expect(isNotesOrganiseRequest(notesOpener))
    #expect(isNotesOrganiseRequest("Organise my notes"))
    #expect(isNotesOrganiseRequest("  organize my notes, please"))
  }

  @Test func shouldLeaveAnyOtherMessageAlone() {
    #expect(!isNotesOrganiseRequest("Give me a few ideas for chapter 1, from where the story stands."))
    #expect(!isNotesOrganiseRequest("Do not organise my notes yet."))
  }

  @Test func shouldCatchAPageTitledAsPlansOnAPageTheChapterWriterReads() throws {
    #expect(writesPlansOnWriterPage(try op(plansPage)))
    #expect(writesPlansOnWriterPage(try op(##"{"op":"bible_document.upsert","section":"plot","slug":"default","body":"# Future events\n\nThey marry."}"##)))
    #expect(writesPlansOnWriterPage(try op(#"{"op":"bible_document.upsert","section":"plot","slug":"later-plans","body":"x"}"#)))
    #expect(writesPlansOnWriterPage(try page(plansPage, title: "What happens next")))
  }

  @Test func shouldLetPlansOntoThePlannerOnlyTimelineAndTheWriterExcludedEscalationMap() throws {
    #expect(!writesPlansOnWriterPage(try page(plansPage, "project", "timeline")))
    #expect(!writesPlansOnWriterPage(try page(plansPage, "plot", "escalation-map")))
  }

  @Test func shouldLeaveWorldPagesWhosTitlesOnlyContainAPlanWordAndEveryOtherOp() throws {
    #expect(!writesPlansOnWriterPage(try op(openingPage)))
    #expect(!writesPlansOnWriterPage(try page(openingPage, title: "Battle plans of the north")))
    #expect(!writesPlansOnWriterPage(try page(openingPage, title: "The future city")))
    #expect(!writesPlansOnWriterPage(try op(#"{"op":"bible_document.remove","section":"plot","slug":"plans"}"#)))
    #expect(!writesPlansOnWriterPage(try op(#"{"op":"entity.upsert","entityKey":"plans","type":"concept"}"#)))
  }

  @Test func shouldReadAHeadingAfterBlankSpaceThatSpansLinesLikeTheReferenceDoes() throws {
    #expect(writesPlansOnWriterPage(try op(##"{"op":"bible_document.upsert","section":"plot","slug":"default","body":"#\nPlans\nmore"}"##)))
    #expect(writesPlansOnWriterPage(try op(#"{"op":"bible_document.upsert","section":"plot","slug":"default","body":"intro\r\n# Roadmap\r\nx"}"#)))
    #expect(!writesPlansOnWriterPage(try op(#"{"op":"bible_document.upsert","section":"plot","slug":"default","body":"  # Plans"}"#)))
  }

  @Test func shouldAskANotesOrganiseRequestForTheOrganiseActionAlone() throws {
    #expect(laterPlanIssues([try op(openingPage), try op(plansPage)], organiseRequest: true).first?.contains(#"{"op":"action.organise_notes"}"#) == true)
    #expect(laterPlanIssues(nil, organiseRequest: true).count == 1)
    #expect(laterPlanIssues([try op(organise)], organiseRequest: true).isEmpty)
  }

  @Test func shouldSendAPlansPageToTheTimelineUnderItsLaterBands() throws {
    let issues = laterPlanIssues([try op(openingPage), try op(plansPage)], organiseRequest: false)
    #expect(issues.count == 1)
    #expect(issues[0].hasPrefix("changeSet[1]: plot/default holds plans for later"))
    #expect(issues[0].contains("bible_document.upsert project/timeline"))
    #expect(issues[0].contains(###""## Early on", "## Later", "## The ending", "## Not yet placed""###))
  }

  @Test func shouldStageTheOrganiseActionAloneForANotesOrganiseRequestAndSayWhy() throws {
    let routed = withLaterPlansRouted(TurnOutput(reply: "Organised.", changeSet: [try op(openingPage), try op(plansPage)]), organise: .start)
    #expect(routed.changeSetTexts == [organise])
    #expect(routed.reply == "Organised.\n\n\(organiseRoutedNote)")
    #expect(withLaterPlansRouted(TurnOutput(reply: "Organised."), organise: .card).reply == "Organised.\n\n\(organiseRoutedNote) \(organiseCardNote)")
  }

  @Test func shouldAddTheOrganiseActionToAReplyThatProposedNothingAndLeaveOneThatProposedItAlone() throws {
    #expect(withLaterPlansRouted(TurnOutput(reply: "Sure."), organise: .start).changeSetTexts == [organise])
    let proposed = TurnOutput(reply: "Accept the card.", changeSet: [try op(organise)])
    let staged = withLaterPlansRouted(proposed, organise: .card)
    #expect(staged.reply == proposed.reply && staged.changeSetTexts == proposed.changeSetTexts)
  }

  @Test func shouldWithholdAPlansPageFromAnyOtherTurnAndKeepTheRest() throws {
    let routed = withLaterPlansRouted(
      TurnOutput(reply: "Saved.", changeSet: [try op(openingPage), try op(plansPage)], question: .object(OrderedJSONObject([(key: "q", value: .int(1))]))), organise: .none)
    #expect(routed.changeSet.map { $0.count } == 1)
    #expect(routed.reply == "Saved.\n\n\(plansWithheldNote)")
    #expect(routed.question?.jsonText == #"{"q":1}"#)
    let alone = withLaterPlansRouted(TurnOutput(reply: "Saved.", changeSet: [try op(plansPage)]), organise: .none)
    #expect(alone.changeSet == nil && alone.reply == "Saved.\n\n\(plansWithheldNote)")
  }

  @Test func shouldLeaveATurnWithNoPlansPageUntouched() throws {
    let output = TurnOutput(reply: "Saved.", changeSet: [try op(openingPage)])
    let staged = withLaterPlansRouted(output, organise: .none)
    #expect(staged.reply == output.reply && staged.changeSetTexts == output.changeSetTexts)
  }
}
