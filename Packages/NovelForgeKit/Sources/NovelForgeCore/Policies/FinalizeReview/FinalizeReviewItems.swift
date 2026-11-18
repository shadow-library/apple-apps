private struct Draft {
  var basis: FinalizeBasis
  var subjectKey: String
  var claim: String
  var evidence: String?
  var proposed: ProposedChange
  var consequential: Bool
  var flag: FinalizeFlag?
  var dependents: [String]?
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:65
private let ruleEntityTypes: Set<EntityType> = [.powerRule, .concept]

private let subjectBoundCategories: Set<FinalizeCategory> = [.appearance, .characterState, .relationship, .knowledge]

private func nonEmpty(_ text: String?) -> String? {
  guard let text, !text.isEmpty else { return nil }
  return text
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:75
private func basisOf(_ confidence: FinalizeExtraction.Confidence?) -> FinalizeBasis {
  confidence == .low ? .inferred : .observed
}

private func typeLabel(_ type: EntityType) -> String {
  var label = type.rawValue
  if let underscore = label.firstIndex(of: "_") { label.replaceSubrange(underscore...underscore, with: " ") }
  return label
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:127
private func entityItems(_ extraction: FinalizeExtraction, _ entityNames: [JSString: String]) -> [Draft] {
  let reported = extraction.newEntities
  let existing = reported.filter { entityNames[JSString($0.entityKey)]?.jsEquals($0.name) == true }.map(\.entityKey).jsUnique()
  let existingKeys = Set(existing.map { JSString($0) })
  let created = reported.filter { !existingKeys.contains(JSString($0.entityKey)) }.map { entity -> Draft in
    let current = entityNames[JSString(entity.entityKey)]
    let claim =
      current.map { "Renames \(entity.entityKey) from \"\($0)\" to \"\(entity.name)\"" }
      ?? "New \(typeLabel(entity.type)): \(entity.name)\(nonEmpty(entity.notes).map { " — \($0)" } ?? "")"
    return Draft(
      basis: .observed, subjectKey: entity.entityKey, claim: claim, evidence: nil, proposed: .entity(entity),
      consequential: current != nil || ruleEntityTypes.contains(entity.type),
      flag: current == nil ? nil : .renamedRecord)
  }
  let createdKeys = Set(created.map { JSString($0.subjectKey) })
  let appeared = (extraction.appeared + existing).jsUnique().filter { !createdKeys.contains(JSString($0)) }.map { entityKey in
    Draft(basis: .observed, subjectKey: entityKey, claim: "\(entityKey) appears in this chapter", evidence: nil, proposed: .appearance(entityKey: entityKey), consequential: false)
  }
  return created + appeared
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:163
private func characterItems(_ extraction: FinalizeExtraction, isolated: Bool) -> [Draft] {
  let states = extraction.characterStates.map { reported -> Draft in
    let state = reported.value
    let change = [
      nonEmpty(state.location).map { "at \($0)" }, state.conditions.flatMap { nonEmpty($0.joined(separator: ", ")) }, nonEmpty(state.immediateGoal).map { "wants to \($0)" },
      nonEmpty(state.statusNote),
    ]
    .compactMap { $0 }.joined(separator: "; ")
    return Draft(
      basis: basisOf(reported.confidence), subjectKey: state.entityKey, claim: "\(state.entityKey) is now \(change.isEmpty ? "unchanged" : change)", evidence: state.evidence,
      proposed: .characterState(state), consequential: isolated || reported.confidence == .low)
  }
  let relationships = extraction.relationships.map { reported -> Draft in
    let relationship = reported.value
    return Draft(
      basis: basisOf(reported.confidence), subjectKey: relationship.entityKey,
      claim: "\(relationship.entityKey) → \(relationship.targetKey): \(relationship.kind)\(nonEmpty(relationship.note).map { " (\($0))" } ?? "")", evidence: relationship.evidence,
      proposed: .relationship(relationship), consequential: reported.confidence == .low)
  }
  return states + relationships
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:197
private func promiseItems(_ extraction: FinalizeExtraction, closedThreads: Set<JSString>, resolvedMysteries: Set<JSString>) -> [Draft] {
  let threads = extraction.threads.map { reported -> Draft in
    let thread = reported.value
    let reopens = thread.status == .open && closedThreads.contains(JSString(thread.threadKey))
    let label = thread.summary ?? thread.threadKey
    return Draft(
      basis: basisOf(reported.confidence), subjectKey: thread.threadKey, claim: reopens ? "Reopens: \(label)" : thread.status == .closed ? "Paid off: \(label)" : "Open: \(label)",
      evidence: nil, proposed: .thread(thread), consequential: reopens || thread.status != .open || reported.confidence == .low, flag: reopens ? .reopenedPromise : nil)
  }
  let mysteries = extraction.mysteries.map { reported -> Draft in
    let mystery = reported.value
    let reopens = mystery.status == .open && resolvedMysteries.contains(JSString(mystery.mysteryKey))
    let label = mystery.question ?? mystery.mysteryKey
    return Draft(
      basis: basisOf(reported.confidence), subjectKey: mystery.mysteryKey,
      claim: reopens ? "Reopens the question: \(label)" : mystery.status == .resolved ? "Answered: \(label)" : "Open question: \(label)", evidence: nil,
      proposed: .mystery(mystery),
      consequential: reopens || mystery.status != .open || nonEmpty(mystery.truthFactKey) != nil || reported.confidence == .low, flag: reopens ? .reopenedPromise : nil)
  }
  return threads + mysteries
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:229
private func knowledgeItems(_ material: FinalizeReviewMaterial) -> [Draft] {
  let facts = material.facts.jsLastByKey { $0.factKey }
  let planned = Set(material.plannedLearns.map { JSString("\($0.entityKey):\($0.factKey)") })
  return material.extraction.knowledgeChanges.filter { !planned.contains(JSString("\($0.entityKey):\($0.factKey)")) }.map { change -> Draft in
    let locked = facts[JSString(change.factKey)].map { revealRequirements($0, material.unlock) } ?? []
    return Draft(
      basis: .inferred, subjectKey: change.entityKey, claim: "\(change.entityKey) learns \(change.factKey) — \(change.how)", evidence: nil, proposed: .knowledge(change),
      consequential: true, flag: locked.isEmpty ? nil : .unplannedDisclosure, dependents: locked.isEmpty ? nil : locked)
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:250
private func revealsDepending(on milestoneKey: String, _ material: FinalizeReviewMaterial) -> [String]? {
  var without = material.unlock
  without.reachedMilestones.remove(JSString(milestoneKey))
  let planned = Set(material.plannedFactKeys.map { JSString($0) })
  let dependents = material.facts.filter {
    planned.contains(JSString($0.factKey)) && revealRequirements($0, material.unlock).isEmpty && !revealRequirements($0, without).isEmpty
  }
  return dependents.isEmpty ? nil : dependents.map(\.factKey)
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:260
private func milestoneItems(_ material: FinalizeReviewMaterial) -> [Draft] {
  let reported = material.extraction.milestones.jsLastByKey { $0.milestoneKey }
  let known = material.milestones.jsLastByKey { $0.milestoneKey }
  let claimed = material.claimedMilestones.jsUnique()
  let claimedKeys = Set(claimed.map { JSString($0) })
  let claims = claimed.map { milestoneKey -> Draft in
    let entry = reported[JSString(milestoneKey)]
    let label = known[JSString(milestoneKey)]?.label ?? milestoneKey
    let dependents = revealsDepending(on: milestoneKey, material)
    if let entry, entry.reached {
      return Draft(
        basis: .observed, subjectKey: milestoneKey, claim: "Reached: \(label)", evidence: entry.evidence, proposed: .milestone(.init(milestoneKey: milestoneKey, reached: true)),
        consequential: false, dependents: dependents)
    }
    return Draft(
      basis: .inferred, subjectKey: milestoneKey, claim: "The plan claims \"\(label)\", but the prose does not seem to reach it — it stays locked", evidence: nil,
      proposed: .milestone(.init(milestoneKey: milestoneKey, reached: false)), consequential: true, flag: .missedMilestone, dependents: dependents)
  }
  let unclaimed = material.extraction.milestones.jsMapValues { $0.milestoneKey }.compactMap { entry -> Draft? in
    guard entry.reached, !claimedKeys.contains(JSString(entry.milestoneKey)), let milestone = known[JSString(entry.milestoneKey)], milestone.state != .reached else { return nil }
    return Draft(
      basis: .inferred, subjectKey: entry.milestoneKey, claim: "The prose seems to reach \"\(milestone.label)\", which the plan does not claim", evidence: entry.evidence,
      proposed: .milestone(.init(milestoneKey: entry.milestoneKey, reached: true)), consequential: true, flag: .unclaimedMilestone)
  }
  return claims + unclaimed
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:312
private func summaryItems(_ material: FinalizeReviewMaterial) -> [Draft] {
  guard material.isolated, let text = nonEmpty(material.extraction.chapterSummary?.jsTrim()) else { return [] }
  return [
    Draft(
      basis: .inferred, subjectKey: "summary", claim: "What standard chapters will read about this chapter: \(text)", evidence: nil, proposed: .summary(text: text),
      consequential: true)
  ]
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:334
/// An isolated chapter's extraction must already be redacted for standard readers (finalize-review.service.ts:499, standardReadableExtraction).
func buildReviewItems(_ material: FinalizeReviewMaterial) -> [FinalizeReviewItem] {
  let known = Set(material.entityNames.keys).union(material.extraction.newEntities.map { JSString($0.entityKey) })
  let drafts =
    summaryItems(material) + entityItems(material.extraction, material.entityNames) + characterItems(material.extraction, isolated: material.isolated)
    + promiseItems(material.extraction, closedThreads: material.closedThreads, resolvedMysteries: material.resolvedMysteries) + knowledgeItems(material)
    + milestoneItems(material)
  let reachable = drafts.filter { draft in
    if subjectBoundCategories.contains(draft.proposed.category) && !known.contains(JSString(draft.subjectKey)) { return false }
    if case .relationship(let relationship) = draft.proposed, !known.contains(JSString(relationship.targetKey)) { return false }
    return true
  }
  return reachable.jsMapValues { $0.proposed.itemKey }.map { draft -> FinalizeReviewItem in
    let triage: FinalizeTriage = draft.consequential ? .consequential : .routine
    let autoKept = !material.isolated && triage == .routine && material.autoKeep.contains(draft.proposed.category)
    return FinalizeReviewItem(
      itemKey: draft.proposed.itemKey, category: draft.proposed.category, triage: triage, basis: draft.basis, subjectKey: draft.subjectKey, claim: draft.claim,
      evidence: material.isolated && draft.evidence != nil ? FinalizeReviewItem.withheldEvidence : draft.evidence, proposed: draft.proposed, flag: draft.flag,
      dependents: draft.dependents, decision: autoKept ? .kept : nil, edited: nil, reason: nil, autoKept: autoKept)
  }
}
