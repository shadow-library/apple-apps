import Foundation
import ShadowCore
import ShadowStore
import ShadowText

private let novelForgeRegistry = NovelForgeSchema.registry

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

/// What a change set leaves of the records the plan world reads, each edit as its record stands once written; a later edit of a chapter or key replaces an
/// earlier one.
struct PlanOverlay: Sendable, Equatable {
  enum Edit: Sendable, Equatable {
    case plan(chapter: Int, ref: EntityRef, content: ChapterPlanContent)
    case planRemoved(chapter: Int)
    case milestone(String)
    case milestoneRemoved(String)
    case fact(DisclosureFact)
    case factRemoved(String)
    case volume(String, ordinal: Int)
    case volumeRemoved(String)
  }

  private(set) var edits: [Edit]

  init(_ edits: [Edit] = []) {
    self.edits = edits
  }

  mutating func append(_ more: [Edit]) {
    edits += more
  }

  /// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:49: the chapters whose plan the change set writes, the only ones it checks.
  var written: [Int] {
    Array(
      Set(
        edits.compactMap { edit in
          guard case .plan(let chapter, _, _) = edit else { return nil }
          return chapter
        }
      )
    ).sorted()
  }
}

extension NovelPlanWorld {
  /// apps/novel-forge-server/src/common/plan-state.ts:32 (enforcePlanWrite) for one plan as it would stand once written: its milestone claims, the single
  /// ending and the reveal rule, judged as D20's verdicts judge the plans that stand.
  func refusal(of content: ChapterPlanContent, ref: EntityRef, novel: UUID, chapter: Int) throws(DomainError) -> DomainError? {
    try refusal(of: PlanOverlay([.plan(chapter: chapter, ref: ref, content: content)]), novel: novel)
  }

  /// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:46 (enforcePlanOps): every written plan, in chapter order, judged against the world as
  /// the whole overlay leaves it, so one edit may rely on another; the first refusal is returned.
  func refusal(of overlay: PlanOverlay, novel: UUID) throws(DomainError) -> DomainError? {
    let laid = try LaidPlanWorld(self, overlay, novel: novel)
    for chapter in overlay.written {
      guard let written = laid.written[chapter] else { continue }
      let claims = written.plan.claims
      let problems = findPlanClaimProblems(claims, laid.raw)
      if !problems.isEmpty { return .planClaims(chapter: chapter, reason: problems.joined(separator: "; ")) }
      if claims.isEnding, let rival = Self.keepingLatestEnding(laid.standing.filter { $0.claims.chapter != chapter }).first(where: \.claims.isEnding) {
        return .endingPlanned(rival.claims.chapter)
      }
      guard let row = laid.judged.plans.first(where: { $0.claims.chapter == chapter }) else { continue }
      let violations = Self.revealViolations(of: row, at: laid.context(chapter), factByKey: laid.factByKey, unreadable: laid.unreadableSecrets)
      guard violations.isEmpty else {
        let rendered = renderRevealRuleViolations(violations.map { RevealRuleViolation(factKey: $0.fact, missing: $0.missing) })
        return .planRevealsLocked(chapter: chapter, violations: rendered)
      }
    }
    return nil
  }

  /// apps/novel-forge-server/src/common/brief-volume.ts:9 over the chapters the world reads.
  func nearestVolume(to chapter: Int) -> String? {
    nearestVolumeKey(chapters.map { PlanClaims(chapter: $0.chapter, volumeKey: $0.volume, isEnding: $0.ending, claimedMilestones: $0.claims) }, chapter: chapter)
  }
}

private enum PlanReplacement {
  case written(WorldChapter)
  case removed
}

/// The stored world with an overlay laid over it. A removed plan leaves a final chapter's canon standing; milestone rows keep their stored reached state,
/// which only a final chapter changes.
private struct LaidPlanWorld {
  let written: [Int: WorldChapter]
  let standing: [DisclosurePlan]
  let raw: PlanWorld
  let judged: PlanWorld
  let context: (Int) -> UnlockContext
  let factByKey: [JSString: DisclosureFact]
  let unreadableSecrets: Set<JSString>

  init(_ world: NovelPlanWorld, _ overlay: PlanOverlay, novel: UUID) throws(DomainError) {
    let base = world.planWorld
    var replaced = [Int: PlanReplacement]()
    var milestones = [JSString: Bool]()
    var facts = world.facts.map(\.disclosureFact).jsLastByKey(\.factKey)
    var unreadable = Set(world.unreadableSecrets.map { JSString($0) })
    var ordinals = base.volumeOrdinals
    for edit in overlay.edits {
      switch edit {
      case .plan(let chapter, let ref, let content): replaced[chapter] = .written(try Self.chapter(content, ref: ref, novel: novel, chapter: chapter))
      case .planRemoved(let chapter): replaced[chapter] = .removed
      case .milestone(let key): milestones[JSString(key)] = true
      case .milestoneRemoved(let key): milestones[JSString(key)] = false
      case .fact(let fact):
        facts[JSString(fact.factKey)] = fact
        unreadable.remove(JSString(fact.factKey))
      case .factRemoved(let key):
        facts[JSString(key)] = nil
        unreadable.remove(JSString(key))
      case .volume(let key, let ordinal): ordinals[JSString(key)] = ordinal
      case .volumeRemoved(let key): ordinals[JSString(key)] = nil
      }
    }
    var written = [Int: WorldChapter]()
    for case (let chapter, .written(let laid)) in replaced { written[chapter] = laid }
    let kept = world.chapters.filter { chapter in
      switch replaced[chapter.chapter] {
      case nil: true
      case .removed?: chapter.basis == .canon
      case .written?: false
      }
    }
    let standing = (kept + written.values).sorted { $0.chapter < $1.chapter }.map(\.plan)
    let stored = base.milestones.filter { milestones[JSString($0.milestoneKey)] != false }
    let storedKeys = Set(stored.map { JSString($0.milestoneKey) })
    let added = milestones.filter { $0.value && !storedKeys.contains($0.key) }.map(\.key.value).jsSorted()
    let rows = stored + added.map { MilestoneRow(milestoneKey: $0, state: .open, reachedChapter: nil) }
    self.written = written
    self.standing = standing
    raw = PlanWorld(plans: standing.map(\.row), milestones: rows, volumeOrdinals: ordinals)
    judged = PlanWorld(plans: NovelPlanWorld.keepingLatestEnding(standing).map(\.row), milestones: rows, volumeOrdinals: ordinals)
    context = plannedUnlockContexts(judged, conditioned: true)
    factByKey = facts
    unreadableSecrets = unreadable
  }

  private static func chapter(_ content: ChapterPlanContent, ref: EntityRef, novel: UUID, chapter: Int) throws(DomainError) -> WorldChapter {
    let entry = try storeCall { () throws(StoreError) in
      try ChapterContractEntry.reading(.plan, ref, novel: novel, chapter: chapter, volume: content.volume, contract: content.contract)
    }
    guard let terms = try? JSONDecoder().decode(ChapterTerms.self, from: entry.terms) else { throw .store(.corruptStore("a plan's terms cannot be read back")) }
    return WorldChapter(ChapterContractReading(entry: entry, terms: terms))
  }
}
