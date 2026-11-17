import Foundation
import ShadowCore
import ShadowStore

private let novelForgeRegistry = SchemaRegistry(version: NovelForgeSchema.version, entities: NovelForgeSchema.entities)

extension WriteTransaction {
  /// The novel's plan world as reconciled at the transaction's start (D20's stored world); refuses while that world or what it is built from is faulted, or
  /// missing although the novel has records it is built from.
  func planWorld(novel: UUID, chapter: Int) throws(DomainError) -> NovelPlanWorld {
    let tables = [PlanWorldEntry.databaseTableName, ChapterContractEntry.databaseTableName, IndexedRecord.databaseTableName]
    guard try !faulted(novel: novel, keyedByNovel: tables), try !inputFaulted(novel: novel) else { throw .planStateUnavailable(chapter) }
    let context = DerivationContext(records: ReadTransaction(database: database, registry: novelForgeRegistry))
    if let world = try storeCall({ () throws(StoreError) in try NovelPlanWorld.stored(for: novel, in: context) }) { return world }
    guard try storeCall({ () throws(StoreError) in try NovelPlanWorld.load(novel: novel, in: context) }) == nil else { throw .planStateUnavailable(chapter) }
    return NovelPlanWorld()
  }

  /// Whether a fault on a single entity can change the novel's plan world: a chapter contract of one of its plans or final chapters, or the record index of
  /// one of its milestones, secrets or volumes. A fault on another kind or another novel's entity cannot; one whose kind or novel cannot be read may.
  private func inputFaulted(novel: UUID) throws(DomainError) -> Bool {
    let watched: [(table: String, kinds: [NovelForgeKind])] = [
      (ChapterContractEntry.databaseTableName, [.chapterPlan, .finalChapter]), (IndexedRecord.databaseTableName, NovelPlanWorld.recordKinds),
    ]
    for (table, kinds) in watched {
      let keys = try faultKeys(of: table).filter { key in ProjectionFaults.kind(ofKey: key).map { kind in kinds.contains { $0.entityKind == kind } } ?? true }
      guard !keys.isEmpty else { continue }
      let owners = try owners(of: kinds)
      if keys.contains(where: { key in owners[key].map { $0 == nil || $0 == novel } ?? true }) { return true }
    }
    return false
  }

  /// Every entity of `kinds` by its fault key, with the novel its natural key names (nil when that cannot be read).
  private func owners(of kinds: [NovelForgeKind]) throws(DomainError) -> [String: UUID?] {
    var owners = [String: UUID?]()
    for kind in kinds {
      let states = try storeCall { () throws(StoreError) in try self.states(ofKind: kind.entityKind, scope: .vault) }
      for (ref, state) in states { owners[ProjectionFaults.key(ref)] = try? NovelForgeKey(reading: state, of: ref).novel }
    }
    return owners
  }
}

extension NovelPlanWorld {
  /// apps/novel-forge-server/src/common/plan-state.ts:32 (enforcePlanWrite) for one plan as it would stand once written: its milestone claims, the single
  /// ending and the reveal rule, judged as D20's verdicts judge the plans that stand.
  func refusal(of content: ChapterPlanContent, ref: EntityRef, novel: UUID, chapter: Int) throws(DomainError) -> DomainError? {
    let entry = try storeCall { () throws(StoreError) in
      try ChapterContractEntry.reading(.plan, ref, novel: novel, chapter: chapter, volume: content.volume, contract: content.contract)
    }
    guard let terms = try? JSONDecoder().decode(ChapterTerms.self, from: entry.terms) else { throw .store(.corruptStore("a plan's terms cannot be read back")) }
    let written = WorldChapter(ChapterContractReading(entry: entry, terms: terms))
    let standing = (chapters.filter { $0.chapter != chapter } + [written]).sorted { $0.chapter < $1.chapter }.map(\.plan)
    let base = planWorld
    let raw = PlanWorld(plans: standing.map(\.row), milestones: base.milestones, volumeOrdinals: base.volumeOrdinals)
    let claims = written.plan.claims
    let problems = findPlanClaimProblems(claims, raw)
    if !problems.isEmpty { return .planClaims(chapter: chapter, reason: problems.joined(separator: "; ")) }
    if let rival = findRivalEnding(claims, raw) { return .endingPlanned(rival) }
    let judged = PlanWorld(plans: Self.keepingLatestEnding(standing).map(\.row), milestones: base.milestones, volumeOrdinals: base.volumeOrdinals)
    guard let row = judged.plans.first(where: { $0.claims.chapter == chapter }) else { return nil }
    let violations = revealJudge(row, plannedUnlockContexts(judged, conditioned: true)(chapter))
    guard !violations.isEmpty else { return nil }
    let rendered = renderRevealRuleViolations(violations.map { RevealRuleViolation(factKey: $0.fact, missing: $0.missing) })
    return .planRevealsLocked(chapter: chapter, violations: rendered)
  }

  /// apps/novel-forge-server/src/common/brief-volume.ts:9 over the chapters the world reads.
  func nearestVolume(to chapter: Int) -> String? {
    nearestVolumeKey(chapters.map { PlanClaims(chapter: $0.chapter, volumeKey: $0.volume, isEnding: $0.ending, claimedMilestones: $0.claims) }, chapter: chapter)
  }
}
