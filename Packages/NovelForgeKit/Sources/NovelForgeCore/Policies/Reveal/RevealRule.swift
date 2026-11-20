import ShadowCore
import ShadowText

public enum MilestoneState: String, CaseIterable, Sendable, Codable {
  case open
  case planned
  case reached
}

public enum FactSource: String, CaseIterable, Sendable, Codable {
  case brief
  case manual
  case `import`
  case seed
  case generated
}

struct PlanClaims: Equatable, Sendable {
  var chapter: Int
  var volumeKey: String?
  var isEnding: Bool
  var claimedMilestones: [String]?
}

struct PlanRow: Equatable, Sendable {
  var claims: PlanClaims
  var knowledgeContract: OrderedJSON
}

struct MilestoneRow: Equatable, Sendable {
  var milestoneKey: String
  var state: MilestoneState
  var reachedChapter: Int?
}

struct RevealFact: Equatable, Sendable {
  var factKey: String
  var revealChapter: Int?
  var unlock: UnlockCondition?
  var source: FactSource
}

struct PlanWorld: Equatable, Sendable {
  var plans: [PlanRow]
  var milestones: [MilestoneRow]
  var volumeOrdinals: [JSString: Int]
}

struct RevealRuleViolation: Equatable, Sendable {
  let factKey: String
  let missing: [String]
}

struct MilestonePlanState: Equatable, Sendable {
  enum Kind: String, Sendable {
    case open
    case planned
  }

  let kind: Kind
  let plannedChapter: Int?
}

struct PlanContextEntry: Equatable, Sendable {
  let planIndex: Int
  let context: UnlockContext
}

struct MilestonePlanEntry: Equatable, Sendable {
  let milestoneKey: String
  let state: MilestonePlanState
}

struct FactPlannedChapter: Equatable, Sendable {
  let factKey: String
  let chapter: Int?
}

let undatedRevealRequirement = "a reveal chapter or an unlock condition"

private func reachedBy(_ world: PlanWorld, chapter: Int) -> Set<JSString> {
  Set(
    world.milestones
      .filter { $0.state == .reached && ($0.reachedChapter.map { $0 <= chapter } ?? true) }
      .map { JSString($0.milestoneKey) }
  )
}

private func endingChapterOf(_ plan: PlanClaims, _ world: PlanWorld) -> Int? {
  if plan.isEnding { return plan.chapter }
  return world.plans.first { $0.claims.isEnding && $0.claims.chapter != plan.chapter }?.claims.chapter
}

private func contextFor(_ plan: PlanClaims, _ world: PlanWorld, reached: Set<JSString>, endingChapter: Int?) -> UnlockContext {
  UnlockContext(chapter: plan.chapter, endingChapter: endingChapter, volumeKey: plan.volumeKey, volumeOrdinals: world.volumeOrdinals, reachedMilestones: reached)
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:66
func planUnlockContext(_ plan: PlanClaims, _ world: PlanWorld) -> UnlockContext {
  var reached = reachedBy(world, chapter: plan.chapter)
  for key in plan.claimedMilestones ?? [] { reached.insert(JSString(key)) }
  for other in world.plans where other.claims.chapter < plan.chapter {
    for key in other.claims.claimedMilestones ?? [] { reached.insert(JSString(key)) }
  }
  return contextFor(plan, world, reached: reached, endingChapter: endingChapterOf(plan, world))
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:76
func planUnlockContexts(_ world: PlanWorld) -> [PlanContextEntry] {
  let endingChapter = world.plans.first { $0.claims.isEnding }?.claims.chapter
  var claimedBefore = Set<JSString>()
  var entries: [PlanContextEntry] = []
  for (index, plan) in Array(world.plans.enumerated()).jsStableSorted(by: { $0.element.claims.chapter < $1.element.claims.chapter }) {
    var reached = reachedBy(world, chapter: plan.claims.chapter).union(claimedBefore)
    for key in plan.claims.claimedMilestones ?? [] { reached.insert(JSString(key)) }
    entries.append(PlanContextEntry(planIndex: index, context: contextFor(plan.claims, world, reached: reached, endingChapter: endingChapter)))
    for key in plan.claims.claimedMilestones ?? [] { claimedBefore.insert(JSString(key)) }
  }
  return entries
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:94
func revealRequirements(_ fact: RevealFact, _ context: UnlockContext) -> [String] {
  if fact.source == .seed && fact.unlock == nil { return [] }
  var missing: [String] = []
  if let revealChapter = fact.revealChapter, revealChapter > context.chapter { missing.append(describeUnlockTerm(.chapter(revealChapter))) }
  if let unlock = fact.unlock {
    missing += evaluateUnlock(unlock, context).missing.map(describeUnlockTerm)
  } else if fact.revealChapter == nil {
    missing.append(undatedRevealRequirement)
  }
  return missing
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:103
func learnedFactKeys(_ knowledgeContract: OrderedJSON) -> [String] {
  (parseKnowledgeContract(knowledgeContract)?.learns.map(\.factKey) ?? []).jsUnique()
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:108
func findPlanRevealViolations(_ plan: PlanRow, facts: [RevealFact], world: PlanWorld, context: UnlockContext? = nil) -> [RevealRuleViolation] {
  let learned = learnedFactKeys(plan.knowledgeContract)
  if learned.isEmpty { return [] }
  let factByKey = facts.jsLastByKey(\.factKey)
  let resolved = context ?? planUnlockContext(plan.claims, world)
  return learned.compactMap { factKey in
    let missing = factByKey[JSString(factKey)].map { revealRequirements($0, resolved) } ?? []
    return missing.isEmpty ? nil : RevealRuleViolation(factKey: factKey, missing: missing)
  }
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:120
func renderRevealRuleViolations(_ violations: [RevealRuleViolation]) -> String {
  violations.map { "\($0.factKey) (needs \($0.missing.joined(separator: " and ")))" }.joined(separator: "; ")
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:125
func findPlanClaimProblems(_ plan: PlanClaims, _ world: PlanWorld) -> [String] {
  let milestoneByKey = world.milestones.jsLastByKey(\.milestoneKey)
  return (plan.claimedMilestones ?? []).flatMap { key -> [String] in
    guard let milestone = milestoneByKey[JSString(key)] else { return ["\(key) is not a milestone of this novel"] }
    if milestone.state == .reached && milestone.reachedChapter != plan.chapter {
      return ["\(key) was already reached in chapter \(milestone.reachedChapter.map { Double($0).jsString } ?? "null")"]
    }
    let rival = world.plans.first { $0.claims.chapter != plan.chapter && ($0.claims.claimedMilestones ?? []).contains { $0.jsEquals(key) } }
    return rival.map { ["\(key) is already claimed by the plan for chapter \(Double($0.claims.chapter).jsString)"] } ?? []
  }
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:136
func findRivalEnding(_ plan: PlanClaims, _ world: PlanWorld) -> Int? {
  guard plan.isEnding else { return nil }
  return world.plans.first { $0.claims.isEnding && $0.claims.chapter != plan.chapter }?.claims.chapter
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:142
func milestonePlanStates(_ world: PlanWorld) -> [MilestonePlanEntry] {
  var earliestClaim: [JSString: Int] = [:]
  for plan in world.plans {
    for key in plan.claims.claimedMilestones ?? [] {
      let slot = JSString(key)
      earliestClaim[slot] = min(plan.claims.chapter, earliestClaim[slot] ?? plan.claims.chapter)
    }
  }
  var order: [JSString] = []
  var states: [JSString: MilestonePlanEntry] = [:]
  for milestone in world.milestones where milestone.state != .reached {
    let slot = JSString(milestone.milestoneKey)
    let state = earliestClaim[slot].map { MilestonePlanState(kind: .planned, plannedChapter: $0) } ?? MilestonePlanState(kind: .open, plannedChapter: nil)
    if states.updateValue(MilestonePlanEntry(milestoneKey: milestone.milestoneKey, state: state), forKey: slot) == nil { order.append(slot) }
  }
  return order.compactMap { states[$0] }
}

// platform/apps/novel-forge-server/src/common/reveal-rule.ts:157
func factPlannedChapters(_ facts: [RevealFact], _ world: PlanWorld, contexts: [PlanContextEntry]? = nil) -> [FactPlannedChapter] {
  var order: [JSString] = []
  var planned: [JSString: FactPlannedChapter] = [:]
  for fact in facts where planned.updateValue(FactPlannedChapter(factKey: fact.factKey, chapter: nil), forKey: JSString(fact.factKey)) == nil {
    order.append(JSString(fact.factKey))
  }
  let factByKey = facts.jsLastByKey(\.factKey)
  for entry in contexts ?? planUnlockContexts(world) {
    let plan = world.plans[entry.planIndex]
    for factKey in learnedFactKeys(plan.knowledgeContract) {
      let slot = JSString(factKey)
      guard let fact = factByKey[slot], let current = planned[slot], current.chapter == nil, revealRequirements(fact, entry.context).isEmpty else { continue }
      planned[slot] = FactPlannedChapter(factKey: current.factKey, chapter: plan.claims.chapter)
    }
  }
  return order.compactMap { planned[$0] }
}
