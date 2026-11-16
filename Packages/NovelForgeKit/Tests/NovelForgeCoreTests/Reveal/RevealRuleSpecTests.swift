import Testing

@testable import NovelForgeCore

private let rankFour = fact("lamp_rank_4_rule", unlock: UnlockCondition(all: [.milestone("lamp_rank_4")]))
private let openRule = fact("lamp_costs_memory", revealChapter: 1)
private let datedSecret = fact("keeper_is_heir", revealChapter: 9)
private let undatedSecret = fact("lamp_is_alive")
private let openMilestones = [milestone("lamp_rank_4", .open)]

struct PlanUnlockContextSpecTests {
  @Test func shouldCountThePlansOwnClaimsAndEveryEarlierPlansClaimsAsReachedButNotALaterPlans() {
    let state = world([plan(3, claimed: ["a"]), plan(5, claimed: ["b"]), plan(8, claimed: ["c"])])

    #expect(reachedList(planUnlockContext(plan(5, claimed: ["b"]).claims, state)) == ["a", "b"])
  }

  @Test func shouldCountAMilestoneAFinalizedChapterReachedButNotForAPlanBeforeThatChapter() {
    let state = world([], milestones: [milestone("a", .reached, reachedChapter: 4)])

    #expect(planUnlockContext(plan(4).claims, state).reachedMilestones.contains("a"))
    #expect(!planUnlockContext(plan(3).claims, state).reachedMilestones.contains("a"))
  }

  @Test func shouldGiveEveryPlanTheSameContextTheOnePlanFormGivesItInOneAscendingPass() {
    let plans = [plan(8, isEnding: true, claimed: ["c"]), plan(3, claimed: ["a"]), plan(5, claimed: ["b"])]
    let state = world(plans, milestones: [milestone("z", .reached, reachedChapter: 4)])

    for entry in planUnlockContexts(state) {
      let alone = planUnlockContext(plans[entry.planIndex].claims, state)
      #expect(entry.context == alone)
    }
    #expect(planUnlockContexts(state).map(\.planIndex) == [1, 2, 0])
  }
}

struct EndingTermSpecTests {
  private let endingSecret = fact("who_lit_the_first_lamp", unlock: UnlockCondition(all: [.ending]))

  @Test func shouldLetTheEndingPlanAndAnEpilogueAfterItRevealAnEndingSecretButNoChapterBeforeTheEnding() {
    let plans = [plan(39), plan(40, isEnding: true), plan(41)]
    let state = world(plans)

    #expect(plans.map { revealRequirements(endingSecret, planUnlockContext($0.claims, state)) } == [["the planned ending or later"], [], []])
    #expect(revealRequirements(endingSecret, planUnlockContext(plan(41).claims, world([plan(41)]))) == ["the planned ending or later"])
  }
}

struct RevealRequirementsSpecTests {
  private let context = planUnlockContext(plan(5).claims, world([]))

  @Test func shouldLetAnyPlanRevealOpenCanonAndAnUnconditionedSeedPromise() {
    #expect(revealRequirements(openRule, context).isEmpty)
    #expect(revealRequirements(fact("reader_promise", source: .seed), context).isEmpty)
  }

  @Test func shouldKeepADatedSecretForItsChapterAndRefuseAnUndatedSecretWithoutAConditionAnywhere() {
    var later = context
    later.chapter = 9
    var distant = context
    distant.chapter = 900

    #expect(revealRequirements(datedSecret, context) == ["chapter 9 or later"])
    #expect(revealRequirements(datedSecret, later).isEmpty)
    #expect(revealRequirements(undatedSecret, distant) == [undatedRevealRequirement])
  }

  @Test func shouldRequireBothTheDateAndTheConditionOfADatedConditionedSecret() {
    let both = fact("both", revealChapter: 9, unlock: UnlockCondition(all: [.milestone("lamp_rank_4")]))
    var met = context
    met.chapter = 9
    met.reachedMilestones = keys(["lamp_rank_4"])

    #expect(revealRequirements(both, context) == ["chapter 9 or later", "milestone lamp_rank_4 reached"])
    #expect(revealRequirements(both, met).isEmpty)
  }
}

struct FindPlanRevealViolationsSpecTests {
  @Test func shouldRefuseALearnWhoseUnlockThePlanDoesNotMeetNamingWhatIsMissing() {
    let chapter = plan(5, contract: learning("lamp_rank_4_rule", "lamp_costs_memory", "unknown_fact"))

    let violations = findPlanRevealViolations(chapter, facts: [rankFour, openRule], world: world([chapter], milestones: openMilestones))

    #expect(violations == [RevealRuleViolation(factKey: "lamp_rank_4_rule", missing: ["milestone lamp_rank_4 reached"])])
  }

  @Test func shouldAllowTheLearnWhenThisPlanOrAnEarlierPlanClaimsTheMilestone() {
    let claiming = plan(5, claimed: ["lamp_rank_4"], contract: learning("lamp_rank_4_rule"))
    let later = plan(7, contract: learning("lamp_rank_4_rule"))
    let state = world([claiming, later], milestones: openMilestones)

    #expect(findPlanRevealViolations(claiming, facts: [rankFour], world: state).isEmpty)
    #expect(findPlanRevealViolations(later, facts: [rankFour], world: state).isEmpty)
  }

  @Test func shouldRenderEachViolationWithWhatItNeedsJoinedByAnd() {
    let violations = [RevealRuleViolation(factKey: "a", missing: ["x", "y"]), RevealRuleViolation(factKey: "b", missing: ["z"])]

    #expect(renderRevealRuleViolations(violations) == "a (needs x and y); b (needs z)")
  }
}

struct FindPlanClaimProblemsSpecTests {
  @Test func shouldRefuseAnUnknownMilestoneOneAnotherPlanClaimsAndOneAnEarlierChapterReached() {
    let milestones = [milestone("lamp_rank_4", .planned), milestone("lamp_rank_3", .reached, reachedChapter: 2)]
    let rival = plan(4, claimed: ["lamp_rank_4"])
    let chapter = plan(6, claimed: ["lamp_rank_4", "lamp_rank_3", "lamp_rank_9"])

    #expect(
      findPlanClaimProblems(chapter.claims, world([rival, chapter], milestones: milestones)) == [
        "lamp_rank_4 is already claimed by the plan for chapter 4",
        "lamp_rank_3 was already reached in chapter 2",
        "lamp_rank_9 is not a milestone of this novel",
      ]
    )
  }

  @Test func shouldLetTheChapterThatReachedAMilestoneKeepClaimingIt() {
    let chapter = plan(2, claimed: ["lamp_rank_3"])

    #expect(findPlanClaimProblems(chapter.claims, world([chapter], milestones: [milestone("lamp_rank_3", .reached, reachedChapter: 2)])).isEmpty)
  }
}

struct FindRivalEndingSpecTests {
  @Test func shouldNameAnotherPlanAlreadyMarkedAsTheEnding() {
    let ending = plan(40, isEnding: true)

    #expect(findRivalEnding(plan(41, isEnding: true).claims, world([ending])) == 40)
    #expect(findRivalEnding(plan(40, isEnding: true).claims, world([ending])) == nil)
    #expect(findRivalEnding(plan(41).claims, world([ending])) == nil)
  }
}

struct MilestonePlanStatesSpecTests {
  @Test func shouldPlanAMilestoneAtItsClaimingChapterOpenOneNobodyClaimsAndLeaveAReachedOneAlone() {
    let states = milestonePlanStates(
      world([plan(6, claimed: ["a"])], milestones: [milestone("a", .open), milestone("b", .planned), milestone("c", .reached, reachedChapter: 2)])
    )

    #expect(
      states == [
        MilestonePlanEntry(milestoneKey: "a", state: MilestonePlanState(kind: .planned, plannedChapter: 6)),
        MilestonePlanEntry(milestoneKey: "b", state: MilestonePlanState(kind: .open, plannedChapter: nil)),
      ])
  }
}

struct FactPlannedChaptersSpecTests {
  @Test func shouldDateEachFactToTheEarliestPlanThatValidlyRevealsItAndLeaveTheRestUndated() {
    let plans = [
      plan(3, contract: learning("lamp_rank_4_rule", "keeper_is_heir")),
      plan(5, claimed: ["lamp_rank_4"], contract: learning("lamp_rank_4_rule")),
      plan(9, contract: learning("keeper_is_heir", "lamp_rank_4_rule")),
    ]

    let planned = factPlannedChapters([rankFour, datedSecret, undatedSecret], world(plans, milestones: openMilestones))

    #expect(planned.map(\.factKey) == ["lamp_rank_4_rule", "keeper_is_heir", "lamp_is_alive"])
    #expect(planned.map(\.chapter) == [5, 9, nil])
  }
}
