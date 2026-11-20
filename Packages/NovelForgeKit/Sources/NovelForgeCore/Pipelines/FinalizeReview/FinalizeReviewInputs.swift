import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowText

/// What a finalize review reads of the novel (apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:469-512): the continuity roster and
/// milestones its call is shown, and what `buildReviewItems` weighs the extraction against. Threads and mysteries are read as the author's records and the
/// winning canons leave them; a fact this device cannot read, or whose unlock it cannot, counts as still locked.
struct FinalizeReviewNovel: Sendable {
  let chapter: Int
  let entities: [EntityRecord]
  let promises: [PromiseStateEntry]
  let milestones: [FinalizeReviewMaterial.Milestone]
  let contract: ChapterContract?
  let planWorld: PlanWorld
  let facts: [RevealFact]
  let autoKeep: Set<FinalizeCategory>
  let pace: Pace

  static func load(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> FinalizeReviewNovel {
    guard case .live(let record) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self) else { throw .novelNotFound(novel) }
    let world = try transaction.planWorld(novel: novel, chapter: chapter)
    guard try !transaction.faulted(novel: novel, keyedByNovel: [PromiseStateEntry.databaseTableName]) else { throw .planStateUnavailable(chapter) }
    let promises = try transaction.fetch(PromiseStateDerivation.request(for: novel))
    let planWorld = world.planWorld
    let states = Dictionary(planWorld.milestones.map { (JSString($0.milestoneKey), $0.state) }, uniquingKeysWith: { first, _ in first })
    let milestones = try transaction.listing(MilestoneRecord.self, novel: novel).map { milestone in
      FinalizeReviewMaterial.Milestone(milestoneKey: milestone.milestone, label: milestone.label, state: states[JSString(milestone.milestone)] ?? .open)
    }
    let facts =
      world.facts.map { fact in
        fact.unlockReadable
          ? RevealFact(factKey: fact.fact, revealChapter: fact.revealChapter, unlock: fact.unlock, source: fact.source ?? .manual) : locked(fact.fact)
      } + world.unreadableSecrets.map(locked)
    return FinalizeReviewNovel(
      chapter: chapter, entities: try transaction.listing(EntityRecord.self, novel: novel), promises: promises, milestones: milestones,
      contract: try transaction.planHead(novel: novel, chapter: chapter)?.record.content.contract, planWorld: planWorld, facts: facts,
      autoKeep: Set(effectiveAutoKeep(record.autoKeep?.compactMap(\.known))), pace: record.costTier.known?.pace ?? .steady)
  }

  private static func locked(_ factKey: String) -> RevealFact {
    RevealFact(factKey: factKey, revealChapter: nil, unlock: nil, source: .manual)
  }

  var claimed: [String] { contract?.claimedMilestones ?? [] }

  // finalize-review.service.ts:480-483
  var contextPack: String {
    let roster = continuityRoster(
      entities: entities.map { ContinuityRosterEntity(entityKey: $0.entity, name: $0.name, type: $0.type.rawValue) },
      threads: promises.filter { $0.promise == .thread }.map { ContinuityRosterThread(threadKey: $0.key, status: $0.status, summary: $0.text) },
      mysteries: promises.filter { $0.promise == .mystery }.map { ContinuityRosterMystery(mysteryKey: $0.key, status: $0.status, question: $0.text) })
    let rows = milestones.map { ContinuityMilestoneRow(milestoneKey: $0.milestoneKey, label: $0.label, state: $0.state.rawValue) }
    return continuityContextPack(roster: roster, milestones: rows, claimed: claimed)
  }

  // finalize-review.service.ts:494-511; the knowledge contract counts only with a POV named (knowledge-contract.ts:16).
  func material(_ extraction: FinalizeExtraction, isolated: Bool) -> FinalizeReviewMaterial {
    let learns = contract?.knowledge?.learns ?? []
    let unlock =
      planWorld.plans.first { $0.claims.chapter == chapter }.map { planUnlockContext($0.claims, planWorld) }
      ?? UnlockContext(chapter: chapter, endingChapter: nil, volumeKey: nil, volumeOrdinals: planWorld.volumeOrdinals, reachedMilestones: [])
    let status = { (kind: PromiseKind, settled: String) in Set(promises.filter { $0.promise == kind && $0.status == settled }.map { JSString($0.key) }) }
    return FinalizeReviewMaterial(
      extraction: isolated ? standardReadableExtraction(extraction) : extraction, isolated: isolated, claimedMilestones: claimed, milestones: milestones,
      entityNames: Dictionary(entities.map { (JSString($0.entity), $0.name) }, uniquingKeysWith: { first, _ in first }),
      closedThreads: status(.thread, ThreadStatus.closed.rawValue), resolvedMysteries: status(.mystery, MysteryStatus.resolved.rawValue),
      plannedLearns: learns.map { FinalizeReviewMaterial.Learn(entityKey: $0.entityKey, factKey: $0.factKey) }, plannedFactKeys: learns.map(\.factKey).jsUnique(),
      facts: facts, unlock: unlock, autoKeep: autoKeep)
  }
}

/// apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:63: what the unrestricted extractor read out of an isolated chapter, every excerpt withheld, so
/// what a standard reader is shown and what may become canon quote nothing of it.
func standardReadableExtraction(_ extraction: FinalizeExtraction) -> FinalizeExtraction {
  var readable = extraction
  let withheld = FinalizeReviewItem.withheldEvidence
  readable.characterStates = extraction.characterStates.map { reported in
    var state = reported
    state.value.evidence = withheld
    return state
  }
  readable.relationships = extraction.relationships.map { reported in
    var relationship = reported
    relationship.value.evidence = withheld
    return relationship
  }
  readable.milestones = extraction.milestones.map { reported in
    var milestone = reported
    milestone.evidence = milestone.evidence.map { _ in withheld }
    return milestone
  }
  return readable
}
