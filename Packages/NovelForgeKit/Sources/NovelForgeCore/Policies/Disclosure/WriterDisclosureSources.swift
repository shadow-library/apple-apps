// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:309
struct LaterVolume: Equatable, Sendable {
  let volumeKey: String
  let title: String?
  let objective: String?
  let body: String?
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:317
struct WriterDisclosureSources: Equatable, Sendable {
  var chapter: Int
  var lockedFacts: [DisclosureFact]
  var ending: String?
  var endingQuestion: String?
  var laterVolumes: [LaterVolume]
  var plannerPages: [DisclosurePage]
  var volumeOrdinals: [JSString: Int]
  var currentVolumeOrdinal: Int?
}

private func present(_ text: String?) -> String? {
  guard let text, !text.jsTrim().isEmpty else { return nil }
  return text
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:333
func writerDisclosurePolicy(_ sources: WriterDisclosureSources) throws(DisclosureError) -> WriterDisclosurePolicy {
  let plannerOnly = ([sources.ending, sources.endingQuestion] + sources.laterVolumes.flatMap { [$0.objective, $0.body] }).compactMap(present)
  return try WriterDisclosurePolicy(
    WriterDisclosureInput(
      chapter: sources.chapter, lockedFacts: sources.lockedFacts, plannerOnly: plannerOnly, plannerPages: sources.plannerPages.compactMap { present($0.body) },
      volumeOrdinals: sources.volumeOrdinals, currentVolumeOrdinal: sources.currentVolumeOrdinal))
}

/// The plan marked as the ending. The reference reads whichever such row the database returns first; of two (a merge can leave them) the later chapter is taken, so no
/// chapter counts as at the ending that the other choice would keep from it.
private func endingPlan(_ plans: [DisclosurePlan]) -> PlanClaims? {
  plans.map(\.claims).filter(\.isEnding).reduce(nil as PlanClaims?) { best, plan in best.map { plan.chapter > $0.chapter ? plan : $0 } ?? plan }
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:348 (loadWriterDisclosureSources and loadDisclosureRecords, which read the project, its plans, volumes and pages)
func writerDisclosureSources(in world: DisclosureWorld, chapter: Int, overlay: DisclosurePlan? = nil) -> WriterDisclosureSources {
  let plan = (overlay ?? world.storedPlan(for: chapter))?.claims
  let storedEnding = endingPlan(world.plans)
  let ending = overlay != nil && storedEnding?.chapter == chapter ? nil : storedEnding
  let volumeKey = plan?.volumeKey ?? nearestVolumeKey(world.plans.map(\.claims), chapter: chapter)
  let volumeOrdinals = world.volumeOrdinals
  let currentVolumeOrdinal = volumeKey.flatMap { volumeOrdinals[JSString($0)] }
  let atEnding = plan?.isEnding == true || ending.map { chapter >= $0.chapter } == true
  let laterVolumes = world.volumes.filter { volume in currentVolumeOrdinal.map { volume.ordinal > $0 } ?? true }.jsStableSorted { $0.ordinal < $1.ordinal }
  return WriterDisclosureSources(
    chapter: chapter, lockedFacts: writerForbiddenFacts(in: world, chapter: chapter, overlay: overlay), ending: atEnding ? nil : present(world.ending),
    endingQuestion: atEnding ? nil : present(world.endingQuestion),
    laterVolumes: laterVolumes.map { LaterVolume(volumeKey: $0.volumeKey, title: $0.title, objective: $0.objective, body: $0.body) },
    plannerPages: world.pages.filter { isPlannerOnlyBibleDoc($0.address) }, volumeOrdinals: volumeOrdinals, currentVolumeOrdinal: currentVolumeOrdinal)
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:404 (loadArtDisclosurePolicy)
func artDisclosurePolicy(in world: DisclosureWorld, chapter: Int) throws(DisclosureError) -> WriterDisclosurePolicy {
  var sources = writerDisclosureSources(in: world, chapter: chapter)
  sources.ending = present(world.ending)
  sources.endingQuestion = present(world.endingQuestion)
  return try writerDisclosurePolicy(sources)
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:413 (loadWriterDisclosurePolicy)
func writerDisclosurePolicy(in world: DisclosureWorld, chapter: Int) throws(DisclosureError) -> WriterDisclosurePolicy {
  try writerDisclosurePolicy(writerDisclosureSources(in: world, chapter: chapter))
}
