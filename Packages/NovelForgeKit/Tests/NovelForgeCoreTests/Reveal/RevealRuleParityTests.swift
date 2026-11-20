import Foundation
import ShadowText
import Testing

@testable import NovelForgeCore

private struct RequirementCase: Decodable {
  let fact: RevealFact
  let context: UnlockContext
  let missing: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    fact = try container.decode(FixtureFact.self).fact
    context = try container.decode(FixtureContext.self).context
    missing = try container.decode([String].self)
  }
}

private struct ContextOutput: Decodable {
  let endingChapter: Int?
  let reached: [String]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    endingChapter = try container.decodeOptional(Int.self)
    reached = try container.decode([String].self)
  }

  func matches(_ context: UnlockContext, chapter: Int, volumeKey: String?, ordinals: [JSString: Int]) -> Bool {
    context.chapter == chapter && context.endingChapter == endingChapter && sameOptional(context.volumeKey, volumeKey) && sameStrings(reachedList(context), reached)
      && context.volumeOrdinals == ordinals
  }
}

private struct ViolationOutput: Decodable {
  let factKey: String
  let missing: [String]

  func matches(_ violation: RevealRuleViolation) -> Bool {
    violation.factKey.jsEquals(factKey) && sameStrings(violation.missing, missing)
  }
}

private func sameViolations(_ actual: [RevealRuleViolation], _ expected: [ViolationOutput]) -> Bool {
  actual.count == expected.count && zip(actual, expected).allSatisfy { $1.matches($0) }
}

private struct FixturePlan: Decodable {
  let row: PlanRow

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let chapter = try container.decode(Int.self)
    let volumeKey = try container.decodeOptional(String.self)
    let isEnding = try container.decode(Int.self) == 1
    let claimed = try container.decodeOptional([String].self)
    let contract = try container.decode(FixtureJSON.self).value
    row = PlanRow(claims: PlanClaims(chapter: chapter, volumeKey: volumeKey, isEnding: isEnding, claimedMilestones: claimed), knowledgeContract: contract)
  }
}

private struct FixtureMilestone: Decodable {
  let row: MilestoneRow

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    let key = try container.decode(String.self)
    let state = try container.decode(String.self)
    let reachedChapter = try container.decodeOptional(Int.self)
    guard let parsed = MilestoneState(rawValue: state) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown state \(state)") }
    row = MilestoneRow(milestoneKey: key, state: parsed, reachedChapter: reachedChapter)
  }
}

private struct FixtureWorld: Decodable {
  let plans: [FixturePlan]
  let milestones: [FixtureMilestone]
  let volumeOrdinals: [OrdinalPair]

  var world: PlanWorld {
    PlanWorld(plans: plans.map(\.row), milestones: milestones.map(\.row), volumeOrdinals: ordinals(volumeOrdinals))
  }
}

private struct PlanOutput: Decodable {
  let context: ContextOutput
  let violations: [ViolationOutput]
  let rendered: String
  let claimProblems: [String]
  let rivalEnding: Int?
  let withContext: [ViolationOutput]?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    context = try container.decode(ContextOutput.self)
    violations = try container.decode([ViolationOutput].self)
    rendered = try container.decode(String.self)
    claimProblems = try container.decode([String].self)
    rivalEnding = try container.decodeOptional(Int.self)
    withContext = try container.decodeOptional([ViolationOutput].self)
  }
}

private struct IndexedContext: Decodable {
  let index: Int
  let context: ContextOutput

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    index = try container.decode(Int.self)
    context = try container.decode(ContextOutput.self)
  }
}

private struct StateOutput: Decodable {
  let key: String
  let state: String
  let plannedChapter: Int?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    struct Body: Decodable {
      let state: String
      let plannedChapter: Int?
    }
    let body = try container.decode(Body.self)
    state = body.state
    plannedChapter = body.plannedChapter
  }
}

private struct PlannedOutput: Decodable {
  let key: String
  let chapter: Int?

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    key = try container.decode(String.self)
    chapter = try container.decodeOptional(Int.self)
  }
}

private struct WorldCase: Decodable {
  let world: PlanWorld
  let facts: [RevealFact]
  let given: UnlockContext
  let contexts: [IndexedContext]
  let perPlan: [PlanOutput]
  let milestoneStates: [StateOutput]
  let planned: [PlannedOutput]

  init(from decoder: any Decoder) throws {
    var container = try decoder.unkeyedContainer()
    world = try container.decode(FixtureWorld.self).world
    facts = try container.decode([FixtureFact].self).map(\.fact)
    var givenContainer = try container.nestedUnkeyedContainer()
    let chapter = try givenContainer.decode(Int.self)
    let endingChapter = try givenContainer.decodeOptional(Int.self)
    let volumeKey = try givenContainer.decodeOptional(String.self)
    let reached = try givenContainer.decode([String].self)
    given = UnlockContext(
      chapter: chapter, endingChapter: endingChapter, volumeKey: volumeKey, volumeOrdinals: world.volumeOrdinals, reachedMilestones: Set(reached.map { JSString($0) }))
    contexts = try container.decode([IndexedContext].self)
    perPlan = try container.decode([PlanOutput].self)
    milestoneStates = try container.decode([StateOutput].self)
    planned = try container.decode([PlannedOutput].self)
  }
}

private struct RevealFixture: Decodable {
  let requirements: [RequirementCase]
  let worlds: [WorldCase]
}

struct RevealRuleParityTests {
  private static func load() throws -> RevealFixture {
    try ReferenceFixture.decode(RevealFixture.self, from: "reveal/reveal.json")
  }

  private static func failures<Element>(_ elements: [Element], where isMismatch: (Element) -> Bool) -> [Int] {
    elements.enumerated().filter { isMismatch($1) }.map(\.offset)
  }

  @Test func shouldCarryAtLeastThreeHundredCasesPerFunction() throws {
    let fixture = try Self.load()
    let plans = fixture.worlds.flatMap(\.perPlan)
    #expect(fixture.requirements.count >= 300)
    #expect(fixture.worlds.count >= 300)
    #expect(plans.count >= 300)
    #expect(plans.contains { !$0.violations.isEmpty } && plans.contains { $0.rivalEnding != nil } && plans.contains { !$0.claimProblems.isEmpty })
    #expect(fixture.worlds.contains { $0.planned.contains { $0.chapter != nil } } && fixture.worlds.contains { !$0.milestoneStates.isEmpty })
    let problems = plans.flatMap(\.claimProblems)
    #expect(problems.filter { $0.contains(" is already claimed by the plan for chapter ") }.count >= 5)
    #expect(problems.filter { $0.contains(" was already reached in chapter ") }.count >= 5)
    #expect(problems.filter { $0.contains(" is not a milestone of this novel") }.count >= 5)
  }

  @Test func shouldListWhatStillHasToHoldAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().requirements) { !sameStrings(revealRequirements($0.fact, $0.context), $0.missing) }
    #expect(bad.isEmpty, "requirements differ for cases \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldBuildTheUnlockContextOfEveryPlanAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      reference.perPlan.count != reference.world.plans.count
        || zip(reference.world.plans, reference.perPlan).contains { plan, output in
          let claims = plan.claims
          return !output.context.matches(planUnlockContext(claims, reference.world), chapter: claims.chapter, volumeKey: claims.volumeKey, ordinals: reference.world.volumeOrdinals)
        }
    }
    #expect(bad.isEmpty, "contexts differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldBuildEveryPlanContextInOneAscendingPassAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      let entries = planUnlockContexts(reference.world)
      guard entries.count == reference.contexts.count else { return true }
      return zip(entries, reference.contexts).contains { entry, output in
        let claims = reference.world.plans[entry.planIndex].claims
        return entry.planIndex != output.index
          || !output.context.matches(entry.context, chapter: claims.chapter, volumeKey: claims.volumeKey, ordinals: reference.world.volumeOrdinals)
      }
    }
    #expect(bad.isEmpty, "ascending contexts differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldFindTheRevealViolationsOfEveryPlanAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      guard reference.perPlan.count == reference.world.plans.count else { return true }
      return reference.perPlan.count != reference.world.plans.count
        || zip(reference.world.plans, reference.perPlan).contains { plan, output in
          !sameViolations(findPlanRevealViolations(plan, facts: reference.facts, world: reference.world), output.violations)
        }
    }
    #expect(bad.isEmpty, "violations differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldFindTheRevealViolationsAgainstAGivenContextAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      guard let plan = reference.world.plans.first, let expected = reference.perPlan.first?.withContext else { return false }
      return !sameViolations(findPlanRevealViolations(plan, facts: reference.facts, world: reference.world, context: reference.given), expected)
    }
    #expect(bad.isEmpty, "violations with a given context differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldRenderTheViolationsWithTheReferenceWording() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      reference.perPlan.count != reference.world.plans.count
        || zip(reference.world.plans, reference.perPlan).contains { plan, output in
          !renderRevealRuleViolations(findPlanRevealViolations(plan, facts: reference.facts, world: reference.world)).jsEquals(output.rendered)
        }
    }
    #expect(bad.isEmpty, "rendering differs for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldFindTheClaimProblemsOfEveryPlanAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      reference.perPlan.count != reference.world.plans.count
        || zip(reference.world.plans, reference.perPlan).contains { plan, output in
          !sameStrings(findPlanClaimProblems(plan.claims, reference.world), output.claimProblems)
        }
    }
    #expect(bad.isEmpty, "claim problems differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldFindTheRivalEndingOfEveryPlanAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      reference.perPlan.count != reference.world.plans.count
        || zip(reference.world.plans, reference.perPlan).contains { plan, output in findRivalEnding(plan.claims, reference.world) != output.rivalEnding }
    }
    #expect(bad.isEmpty, "rival endings differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldMoveOnlyUnreachedMilestonesAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      let actual = milestonePlanStates(reference.world)
      return actual.count != reference.milestoneStates.count
        || zip(actual, reference.milestoneStates).contains {
          !$0.milestoneKey.jsEquals($1.key) || $0.state.kind.rawValue != $1.state || $0.state.plannedChapter != $1.plannedChapter
        }
    }
    #expect(bad.isEmpty, "milestone states differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }

  @Test func shouldDateEachFactToTheEarliestPlanThatRevealsItAsTheReferenceDoes() throws {
    let bad = try Self.failures(Self.load().worlds) { reference in
      let actual = factPlannedChapters(reference.facts, reference.world)
      return actual.count != reference.planned.count || zip(actual, reference.planned).contains { !$0.factKey.jsEquals($1.key) || $0.chapter != $1.chapter }
    }
    #expect(bad.isEmpty, "planned chapters differ for worlds \(bad.prefix(10)) of \(bad.count)")
  }
}
