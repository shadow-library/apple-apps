import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// Who asks for the commit: the author (the app, a chat card they accepted), or approval settling a finalize review that left nothing to ask.
public enum FinalizeInitiator: Sendable, Hashable {
  case author
  case approval
}

/// Finalizing a chapter (apps/novel-forge-server/src/modules/generation/generation.service.ts:583-640, finalize-refusals.ts:12 and commitFinalProse of
/// ai/graphs/chapter-finalization.graph.ts:127-207). The canon is the one first-writer-wins value that makes the chapter final, so everything it binds is
/// decided here: the draft head, the plan head, the approval in force, the plan's contract, what the chapter discloses to the reader, the finalize review it
/// applies (finalize-review-gate.ts:143-181) and the knowledge its approval ledgered. The commit calls no model (decision 2): the review is mandatory, and
/// a chapter with no ready read of its head refuses FRV_002 where the reference would extract continuity on the direct path (chapter-finalization.graph.ts:319-385).
public enum ChapterFinalize {
  /// Finalizes `chapter`, or the lowest approved one, refusing with every refusal `FinalizeCommitGate` names, then writes in one transaction the new entities
  /// its kept items name, the canon with its review binding, and the chapter's canon_refresh request (generation.service.ts:590-602).
  @discardableResult
  public static func finalize(
    novel: UUID, chapter: Int? = nil, by initiator: FinalizeInitiator = .author, origin: JSONValue = .null, in transaction: inout WriteTransaction
  ) throws(DomainError) -> Int {
    let target = try FinalizeCommitGate.check(novel: novel, chapter: chapter, by: initiator, in: transaction)
    let chapter = target.chapter
    let draft = target.head.content
    let plan = try transaction.planHead(novel: novel, chapter: chapter)
    let title = draft.title.map(normalizeLineEndings).flatMap { $0.isEmpty ? nil : $0 }
    let disclosed = plan == nil ? [] : try disclosed(novel: novel, chapter: chapter, in: transaction)
    let binding = FinalizeReviewBinding(target)
    let knowledge = try ledgered(novel: novel, chapter: chapter, revision: target.head.revision, plan: plan?.record.content.contract, in: transaction)
    try createEntities(binding.newEntities, novel: novel, in: &transaction)
    let canon = Canon(
      draftRevision: target.head.revision, planRevision: plan?.revision, approval: target.approval, title: title, body: normalizeLineEndings(draft.body),
      summary: draft.summary, generator: draft.generator, isolated: draft.isolated, volume: plan?.record.content.volume,
      contract: plan?.record.content.contract ?? ChapterContract(), disclosed: disclosed, review: binding.review, knowledge: knowledge)
    let record = try storeCall { () throws(StoreError) in try finalRecord(novel: novel, chapter: chapter, canon) }
    let outcome = try storeCall { () throws(StoreError) in try record.finalize(in: &transaction) }
    guard case .finalized(let change) = outcome else { throw .draftFinal(chapter) }
    if let plan {
      _ = try storeCall { () throws(StoreError) in try ChapterPlanRecord.mark(plan.record.ref, revision: plan.revision, [.finalized], in: &transaction) }
    }
    try CanonRefreshJobs.request(
      novel: novel, chapter: chapter, canonDigest: record.canonDigest, review: CanonRefreshReview(binding.review), origin: origin, requester: change.clock.replica,
      in: &transaction)
    return chapter
  }

  /// apps/novel-forge-server/src/common/provisional-knowledge.ts:130 at finalize, for a chapter that has a plan: what it shows the reader on the plan world as it
  /// stands, secrets an earlier chapter already disclosed included.
  static func disclosed(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> [String] {
    let world = try transaction.planWorld(novel: novel, chapter: chapter)
    return world.disclosureWorld(plans: world.chapters.map(\.plan)).chapterReveals(chapter: chapter)
  }

  /// commitChapterKnowledge (provisional-knowledge.ts:163-175, chapter-finalization.graph.ts:175): the pairs the approval of `revision` ledgered at this chapter,
  /// which the canon freezes; nil, so readers recompute, where the ledger is not derived. A learner or fact the plan teaches that this version cannot read
  /// refuses, as the ledger leaves its pair out and the freeze would keep it out once the record reads again.
  static func ledgered(
    novel: UUID, chapter: Int, revision: String, plan: ChapterContract?, in transaction: borrowing WriteTransaction
  ) throws(DomainError) -> [KnowledgeReveal]? {
    for learn in plan?.knowledge?.learns ?? [] {
      _ = try transaction.presence(EntityRecord.ref(novel: novel, entity: learn.entityKey), as: EntityRecord.self)
      _ = try transaction.presence(SecretRecord.ref(novel: novel, secret: learn.factKey), as: SecretRecord.self)
    }
    let rows = try transaction.sql { database -> [CharacterKnowledgeEntry]? in
      guard try database.tableExists(CharacterKnowledgeEntry.databaseTableName) else { return nil }
      return try CharacterKnowledgeDerivation.request(for: novel).filter(
        Column("chapter") == chapter && Column("source") == FactSource.brief.rawValue && Column("status") == KnowledgeStatus.provisional.rawValue
          && Column("draft") == revision
      ).fetchAll(database)
    }
    return rows?.map { KnowledgeReveal(entityKey: $0.entity, factKey: $0.fact) }
  }

  /// review-event-apply.ts:190-193 through apply-continuity.ts:84-102: a kept entity the novel has no live record of is created as generated; a live one is left
  /// as the author keeps it (G27: no rename).
  private static func createEntities(_ entities: [ProposedChange.Entity], novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) {
    for entity in entities where !entity.entityKey.isEmpty {
      let ref = EntityRecord.ref(novel: novel, entity: entity.entityKey)
      if case .live = try transaction.presence(ref, as: EntityRecord.self) { continue }
      try transaction.create(
        EntityRecord(novel: novel, entity: entity.entityKey, type: .known(entity.type), name: entity.name, origin: .known(.generated), notes: entity.notes))
    }
  }

  private static func finalRecord(novel: UUID, chapter: Int, _ canon: Canon) throws(StoreError) -> FinalChapterRecord {
    do throws(NovelForgeKeyError) {
      return try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon)
    } catch {
      throw .invalidChange(error.errorDescription ?? error.code)
    }
  }
}

/// What the canon records of the review it applied: every kept or edited item's effective change in the review's order (an item this version cannot read as
/// it was stored or edited, for a version that can), and the claims the answers leave unreached (finalize-review-gate.ts:157-166).
struct FinalizeReviewBinding {
  let review: CanonReview
  let newEntities: [ProposedChange.Entity]

  init(_ target: FinalizeCommitTarget) {
    let answered = target.answers[target.head.revision] ?? [:]
    var kept = [[String: JSONValue]]()
    var entities = [ProposedChange.Entity]()
    for entry in target.review.items {
      if let item = entry.item {
        guard item.decision == .kept || item.decision == .edited else { continue }
        let change = effectiveChange(item)
        kept.append(change.json.objectValue ?? [:])
        if case .entity(let entity) = change { entities.append(entity) }
        continue
      }
      let answer = answered[entry.stored.key]
      let decision = answer?.decision.known ?? entry.stored.autoDecision?.known
      guard decision == .kept || decision == .edited else { continue }
      kept.append(decision == .edited ? answer?.edit ?? entry.stored.proposed : entry.stored.proposed)
    }
    review = CanonReview(id: target.review.read.record.id, kept: kept, unreached: unreachedClaims(target.review.resolved).map(\.subjectKey))
    newEntities = entities
  }
}

extension VaultStore {
  /// FRV_002 asks for the head's review in a write of its own, as the refusal abandons the commit's (decision 2); the app runs it through `finalizeReviewJob`.
  @discardableResult
  public func finalizeChapter(novel: UUID, chapter: Int? = nil) async throws(DomainError) -> Int {
    do throws(DomainError) {
      return try await writeDomain { transaction throws(DomainError) in try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction) }
    } catch {
      try await requestFinalizeReview(after: error, novel: novel)
      throw error
    }
  }

  /// Any refusal other than FRV_002 asks for nothing.
  func requestFinalizeReview(after refusal: DomainError, novel: UUID) async throws(DomainError) {
    guard case .finalizeRefused(.reviewPreparing(let chapter)) = refusal else { return }
    let requester = replica
    try await writeDomain { transaction throws(DomainError) in
      guard try !transaction.isFinal(novel: novel, chapter: chapter), case .live(let head) = try transaction.draft(novel: novel, chapter: chapter) else { return }
      let input = FinalizeReviewJobInput(revision: head.revision, body: head.content.body, plan: try transaction.planHead(novel: novel, chapter: chapter)?.revision)
      _ = try FinalizeReviewJobs.request(input, novel: novel, chapter: chapter, requester: requester, in: &transaction)
    }
  }
}
