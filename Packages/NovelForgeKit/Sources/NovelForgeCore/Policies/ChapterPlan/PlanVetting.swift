import ShadowText

private func claimable(_ key: String, _ plan: PlanClaims, _ world: PlanWorld) -> Bool {
  var claiming = plan
  claiming.claimedMilestones = [key]
  return findPlanClaimProblems(claiming, world).isEmpty
}

private func holdsAt(_ fact: PlanFact, _ plan: PlanClaims, _ world: PlanWorld) -> Bool {
  revealRequirements(fact.reveal, planUnlockContext(plan, world)).isEmpty
}

private func lockedReveals(_ facts: [PlanFact], _ plan: PlanClaims, _ world: PlanWorld) -> [ScheduledReveal] {
  let context = planUnlockContext(plan, world)
  return scheduledReveals(facts) { evaluateUnlock($0, context).holds }.filter { isRevealLocked($0, chapter: plan.chapter) }
}

private func keptClaims(_ output: PlannedChapter, _ plan: PlanClaims, _ world: PlanWorld) -> (kept: [String], dropped: [String]) {
  let proposed = normalizeStringList(output.claimedMilestones ?? [])
  let kept = proposed.filter { claimable($0, plan, world) }
  return (kept, proposed.filter { key in !kept.contains { $0.jsEquals(key) } })
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:196
func renderPlanMilestones(_ milestones: [PlanMilestone], facts: [PlanFact], plan: PlanClaims, world: PlanWorld) -> String {
  let lines =
    milestones
    .filter { $0.state != .reached && claimable($0.milestoneKey, plan, world) }
    .map { milestone -> String in
      var claimed = plan
      claimed.claimedMilestones = (plan.claimedMilestones ?? []) + [milestone.milestoneKey]
      let unlocks = facts.filter { $0.unlock != nil && !holdsAt($0, plan, world) && holdsAt($0, claimed, world) }.map(\.factKey)
      let subject = milestone.subjectEntityKey.map { " (\($0))" } ?? ""
      let opens = unlocks.isEmpty ? "" : " — claiming it unlocks: \(unlocks.joined(separator: ", "))"
      return "- \(milestone.milestoneKey): \(milestone.label)\(subject)\(opens)"
    }
  return lines.isEmpty ? "(none open)" : lines.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:221
func planAdvice(_ output: PlannedChapter, plan: PlanClaims, facts: [PlanFact], world: PlanWorld) throws(DisclosureError) -> [String] {
  let (kept, dropped) = keptClaims(output, plan, world)
  let claims = dropped.map { "claimedMilestones names \($0), which this chapter cannot claim — claim only a milestone from the MILESTONES list" }
  var claiming = plan
  claiming.claimedMilestones = kept
  let violations = try findBriefRevealViolations(output, chapter: plan.chapter, reveals: lockedReveals(facts, claiming, world))
  return claims + violations.map(renderRevealViolation)
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:232
func vetPlan(_ output: PlannedChapter, plan: PlanClaims, facts: [PlanFact], world: PlanWorld) throws(DisclosureError) -> VettedPlan {
  let (kept, dropped) = keptClaims(output, plan, world)
  var claims = plan
  claims.claimedMilestones = kept
  let factByKey = facts.jsLastByKey(\.factKey)
  var withLearns = output
  if let contract = output.knowledgeContract {
    withLearns.knowledgeContract?.learns = (contract.learns ?? []).filter { learn in factByKey[JSString(learn.factKey)].map { holdsAt($0, claims, world) } ?? false }
  }
  let reveals = lockedReveals(facts, claims, world)
  let (safe, sanitised) = try sanitiseBriefReveals(withLearns, chapter: plan.chapter, reveals: reveals)
  var moves = output.moves
  if let text = output.moves, !text.isEmpty { moves = try sanitiseRevealText(text, chapter: plan.chapter, reveals: reveals) }
  return VettedPlan(chapter: plan.chapter, plan: safe, moves: moves, claimedMilestones: kept, droppedClaims: dropped, sanitised: sanitised)
}

// apps/novel-forge-server/src/modules/actions/chapter-plan.ts:248
func resolveScenePovs(_ plan: PlannedChapter, characterKeys: Set<JSString>) -> PlannedChapter {
  var resolved = plan
  resolved.scenes = plan.scenes.map { scene in
    var scene = scene
    let pov = scene.pov?.jsTrim()
    scene.pov = pov.flatMap { !$0.isEmpty && characterKeys.contains(JSString($0)) ? $0 : nil }
    return scene
  }
  if var contract = plan.knowledgeContract {
    contract.pov = contract.pov.filter { characterKeys.contains(JSString($0)) }
    contract.learns = contract.learns?.filter { characterKeys.contains(JSString($0.entityKey)) }
    resolved.knowledgeContract = contract
  }
  return resolved
}
