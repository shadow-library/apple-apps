// apps/novel-forge-server/src/common/brief-volume.ts:9 (nearestVolumeKey, which queried the plans; an empty key counts as none before the chapter, as the reference's truthiness test does)
func nearestVolumeKey(_ plans: [PlanClaims], chapter: Int) -> String? {
  let planned = plans.filter { $0.volumeKey != nil }
  let before = planned.filter { $0.chapter <= chapter }.reduce(nil as PlanClaims?) { best, plan in best.map { plan.chapter > $0.chapter ? plan : $0 } ?? plan }
  if let key = before?.volumeKey, !key.isEmpty { return key }
  let after = planned.filter { $0.chapter > chapter }.reduce(nil as PlanClaims?) { best, plan in best.map { plan.chapter < $0.chapter ? plan : $0 } ?? plan }
  return after?.volumeKey
}

private func bareContext(_ chapter: Int) -> UnlockContext {
  UnlockContext(chapter: chapter, endingChapter: nil, volumeKey: nil, volumeOrdinals: [:], reachedMilestones: [])
}

// apps/novel-forge-server/src/common/plan-world.ts:81 (chapterUnlockContext, which loaded the plan state)
func chapterUnlockContext(_ world: PlanWorld, chapter: Int, conditioned: Bool, overlay: PlanClaims? = nil) -> UnlockContext {
  guard conditioned else { return bareContext(chapter) }
  let plan =
    overlay ?? world.plans.first { $0.claims.chapter == chapter }?.claims
    ?? PlanClaims(chapter: chapter, volumeKey: nearestVolumeKey(world.plans.map(\.claims), chapter: chapter), isEnding: false, claimedMilestones: [])
  return planUnlockContext(plan, world)
}

// apps/novel-forge-server/src/common/plan-world.ts:67 (plannedUnlockContexts, which loaded the plan state); a chapter without a plan gets no volume
func plannedUnlockContexts(_ world: PlanWorld, conditioned: Bool) -> (Int) -> UnlockContext {
  guard conditioned else { return bareContext }
  let contexts = planUnlockContexts(world)
  return { chapter in
    if let index = world.plans.firstIndex(where: { $0.claims.chapter == chapter }), let entry = contexts.first(where: { $0.planIndex == index }) { return entry.context }
    return planUnlockContext(PlanClaims(chapter: chapter, volumeKey: nil, isEnding: false, claimedMilestones: []), world)
  }
}
