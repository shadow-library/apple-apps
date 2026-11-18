import Foundation
import Testing

@testable import NovelForgeCore

struct ChapterPlanObligationsTests {
  @Test func shouldSelectRenderAndExplainObligationsAsTheReference() throws {
    let cases = try ChapterPlanFixture.cases("obligations")
    #expect(cases.count > 200)
    for (position, item) in cases.enumerated() {
      let sources = obligationSources(try #require(item.object("sources")))
      let selected = selectObligations(sources)
      let actual = selected.map { ["kind": $0.kind.rawValue, "ref": $0.ref ?? "", "text": $0.text] as PlanJSON }
      #expect(ChapterPlanFixture.same(actual, item["obligations"] as Any), "obligations \(position)")
      #expect(renderObligations(selected) == item.text("rendered"), "rendered \(position)")
      for rationale in item.objects("rationales") {
        #expect(planRationale(selected, moves: rationale.text("moves")) == rationale.text("result"), "rationale \(position)")
      }
    }
  }

  @Test func shouldKeepTheEnginesOrderOfAnIntransitiveUrgency() throws {
    let winners = ["a,c,b": "thread:a", "b,c,a": "thread:c", "c,b,a": "thread:c"]
    var seen = Set<String>()
    for item in try ChapterPlanFixture.cases("obligations") {
      let sources = try #require(item.object("sources"))
      let order = sources.objects("threads").compactMap { $0.text("key") }.joined(separator: ",")
      guard sources.number("chapter") == 20, sources.objects("mysteries").isEmpty, let winner = winners[order] else { continue }
      #expect(selectObligations(obligationSources(sources)).first { $0.kind == .promise }?.ref == winner, "\(order)")
      seen.insert(order)
    }
    #expect(seen.count == 3)
  }
}

struct ChapterPlanVettingTests {
  private func run(_ item: PlanJSON) throws -> (input: PlanJSON, output: PlannedChapter, claims: PlanClaims, facts: [PlanFact], world: PlanWorld) {
    let input = try #require(item.object("input"))
    let facts = try input.objects("facts").map(planFact)
    return (input, try plannedChapter(try #require(input.object("output"))), planClaims(try #require(input.object("plan"))), facts, planWorld(try #require(input.object("world"))))
  }

  @Test func shouldVetEveryPlanAsTheReference() throws {
    let cases = try ChapterPlanFixture.cases("vets")
    #expect(cases.count > 150)
    var sanitised = 0
    var advised = 0
    for item in cases {
      let name = item.text("name") ?? ""
      let (_, output, claims, facts, world) = try run(item)
      let vetted = try vetPlan(output, plan: claims, facts: facts, world: world)
      let expected = try #require(item.object("vetted"))
      var plan = try plannedJSON(vetted.plan)
      plan["chapter"] = vetted.chapter
      var expectedPlan = try #require(expected.object("plan"))
      expectedPlan["requiredContext"] = nil
      #expect(ChapterPlanFixture.same(plan, expectedPlan), "plan \(name)")
      #expect(vetted.moves == expected.text("moves"), "moves \(name)")
      #expect(vetted.claimedMilestones == expected.list("claimedMilestones"), "claimed \(name)")
      #expect(vetted.droppedClaims == expected.list("droppedClaims"), "dropped \(name)")
      #expect(ChapterPlanFixture.same(vetted.sanitised.map(violationJSON), expected["sanitised"] as Any), "sanitised \(name)")
      let advice = try planAdvice(output, plan: claims, facts: facts, world: world)
      #expect(advice == item.list("advice"), "advice \(name)")
      sanitised += vetted.sanitised.count
      advised += advice.count
    }
    #expect(sanitised > 100)
    #expect(advised > 100)
  }

  @Test func shouldRenderTheMilestonesAPlanMayClaim() throws {
    for item in try ChapterPlanFixture.cases("vets") {
      let (input, _, claims, facts, world) = try run(item)
      let milestones = input.objects("milestones").map(planMilestone)
      #expect(renderPlanMilestones(milestones, facts: facts, plan: claims, world: world) == item.text("milestones"), "\(item.text("name") ?? "")")
    }
  }

  @Test func shouldClearPointsOfViewThatAreNoCharacter() throws {
    for item in try ChapterPlanFixture.cases("vets") {
      let (input, output, _, _, _) = try run(item)
      let keys = Set((input.list("characterKeys") ?? []).map { JSString($0) })
      var expected = try #require(item.object("resolved"))
      expected["requiredContext"] = nil
      #expect(ChapterPlanFixture.same(try plannedJSON(resolveScenePovs(output, characterKeys: keys)), expected), "\(item.text("name") ?? "")")
    }
  }

  @Test func shouldStageTheWholePlanAsABriefUpdate() throws {
    var cleared = 0
    for item in try ChapterPlanFixture.cases("vets") {
      let name = item.text("name") ?? ""
      let (input, output, claims, facts, world) = try run(item)
      let vetted = try vetPlan(output, plan: claims, facts: facts, world: world)
      let existing = input.object("existing").map { ExistingPlan(hasKnowledgeContract: $0.object("knowledgeContract") != nil, direction: $0.text("direction")) }
      let opInput = PlanOpInput(chapter: claims.chapter, steer: input.text("steer"), rationale: input.text("rationale"))
      let op = chapterPlanOp(opInput, existing: existing, vetted: vetted, contextRefs: input.list("contextRefs") ?? [])
      #expect(ChapterPlanFixture.same(try cardOpJSON(op), try #require(item["op"])), "op \(name)")
      #expect(ChapterPlanFixture.same(try cardOpJSON(emptyPlanOp(opInput)), try #require(item["empty"])), "empty \(name)")
      if case .null = op.update.knowledgeContract { cleared += 1 }
    }
    #expect(cleared > 1)
  }
}

struct ChapterPlanSteeringTests {
  private func rule() throws -> QuoteRule { try #require(QuoteRule.shared) }

  @Test func shouldJudgeWhetherTheAuthorStatedAnIntent() throws {
    let rule = try rule()
    let cases = try ChapterPlanFixture.cases("intentStated")
    for item in cases {
      #expect(
        rule.intentStatedIn(item.text("intent") ?? "", message: item.text("message") ?? "") == item.flag("result"), "\(item.text("intent") ?? "") | \(item.text("message") ?? "")")
    }
    #expect(cases.filter { $0.flag("result") }.count > 10)
  }

  @Test func shouldSteerAsTheReference() throws {
    let rule = try rule()
    for (position, item) in try ChapterPlanFixture.cases("steers").enumerated() {
      let steer = rule.planSteer(intent: item.text("intent"), direction: item.text("direction"), authorMessages: item.list("messages") ?? [])
      let expected = try #require(item.object("result"))
      #expect(steer.intent == expected.text("intent"), "intent \(position)")
      #expect(steer.direction == expected.text("direction"), "direction \(position)")
      #expect(steer.droppedIntent == expected.text("droppedIntent"), "dropped \(position)")
    }
  }

  @Test func shouldReadTheAuthorTurnsTheCardAnswers() throws {
    let cases = try ChapterPlanFixture.cases("windows")
    #expect(cases.count > 15)
    for item in cases {
      let name = item.text("name") ?? ""
      let messages = item.objects("messages").map { message in
        PlanChatMessage(
          id: message.number("id") ?? 0, sessionId: message.text("sessionId") ?? "", isAuthor: message.flag("isAuthor"), content: message.text("content") ?? "",
          contexts: message.objects("contexts").isEmpty ? nil : message.objects("contexts").map(passageContext))
      }
      let proposals = item.objects("proposals").map {
        PriorProposal(id: $0.number("id") ?? 0, sessionId: $0.text("sessionId") ?? "", messageId: $0.number("messageId"), plansChapter: $0.flag("plansChapter"))
      }
      let origin = try #require(item.object("origin"))
      let card = PlanCardOrigin(sessionId: origin.text("sessionId"), messageId: origin.number("messageId"), proposalId: origin.number("proposalId") ?? 0)
      #expect(authorMessagesFor(card, messages: messages, proposals: proposals) == item.list("result"), "\(name)")
    }
  }

  private func passageContext(_ json: PlanJSON) -> ChatPassageContext {
    ChatPassageContext(
      chapter: 1, draftId: "d", revision: 1, saveSeq: 1, start: 0, end: 1, passageHash: "h", quote: json.text("quote") ?? "", comment: json.text("comment") ?? "",
      firstParagraph: 0,
      lastParagraph: 0)
  }
}
