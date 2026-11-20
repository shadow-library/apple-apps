import Foundation
import ShadowCore
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/apply/brief.handler.ts: each write returns its plan as written for the plan rules (apply-rules.ts:46)
enum PlanHandlers: ContentOpHandler {
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    switch operation {
    case .briefUpdate(let update): try write(update, context: context, in: &transaction)
    case .briefRemove(let removal): try remove(chapter: removal.chapter, novel: context.novel, in: &transaction)
    default: throw .noHandler(operation.type)
    }
  }

  /// Writes back what an inverse captured, verbatim (proposal-revert.service.ts:148 applies it as an op): an undo is never refused for its content mode
  /// (apply.types.ts:32), and is refused at or behind the cursor like any plan write.
  static func undo(_ inverse: OrderedJSONObject, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let decoded: PlanRestore
    do throws(ApplyRefusal) {
      decoded = try PlanRestore(inverse)
    } catch {
      throw .refused(error)
    }
    switch decoded {
    case .brief(let brief): return try restore(brief, novel: context.novel, in: &transaction)
    case .removal(let chapter): return try remove(chapter: chapter, novel: context.novel, in: &transaction)
    }
  }

  // brief.handler.ts:52: a missing plan is creatable only with a body, and raised to unrestricted only when the caller allows it
  private static func write(_ update: BriefUpdate, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let chapter = update.chapter
    let (ref, owner) = try open(chapter, novel: context.novel, in: transaction)
    let presence = try planPresence(ref, chapter: chapter, in: transaction)
    var existing: ChapterPlanContent?
    if case .live(let plan) = presence { existing = plan.content }
    if existing == nil, update.body == nil { throw .refused(.notAllowed) }
    if !context.unrestrictedRaise, update.contentMode == .set(.unrestricted), existing?.contentMode != .known(.unrestricted) { throw .refused(.unrestrictedUnavailable) }
    var defaults = PlanDefaults()
    if existing == nil {
      if update.volumeKey == nil { defaults.volume = try nearestVolume(to: chapter, novel: context.novel, in: transaction) }
      if update.contentMode == .omitted { defaults.contentMode = owner.contentMode }
    }
    let content = PlanBriefMerge.merged(existing, update, defaults: defaults)
    try write(content, ref: ref, chapter: chapter, over: presence, novel: context.novel, in: &transaction)
    let inverse = existing.map { BriefRestore($0, chapter: chapter).json } ?? BriefRestore.removal(chapter: chapter)
    return HandlerOutcome(inverse: inverse, planEdits: [.plan(chapter: chapter, ref: ref, content: content)])
  }

  private static func restore(_ restore: BriefRestore, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let chapter = restore.chapter
    let (ref, _) = try open(chapter, novel: novel, in: transaction)
    let presence = try planPresence(ref, chapter: chapter, in: transaction)
    var base = ChapterPlanContent(body: "")
    var inverse = BriefRestore.removal(chapter: chapter)
    switch presence {
    case .live(let plan):
      base = plan.content
      inverse = BriefRestore(plan.content, chapter: chapter).json
    case .removed(let tombstone): base = tombstone.content
    case .absent: break
    }
    let content = restore.restoring(over: base)
    try write(content, ref: ref, chapter: chapter, over: presence, novel: novel, in: &transaction)
    return HandlerOutcome(inverse: inverse, planEdits: [.plan(chapter: chapter, ref: ref, content: content)])
  }

  // brief.handler.ts:83: a plan that is not there is RFN_004; the record is marked removed and keeps its revisions
  private static func remove(chapter: Int, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let (ref, _) = try open(chapter, novel: novel, in: transaction)
    guard case .live(let plan) = try planPresence(ref, chapter: chapter, in: transaction) else { throw .refused(.notAllowed) }
    _ = try handlerStore { () throws(StoreError) in try ChapterPlanRecord.remove(ref, in: &transaction) }
    return HandlerOutcome(inverse: BriefRestore(plan.content, chapter: chapter).json, planEdits: [.planRemoved(chapter: chapter)])
  }

  // brief.handler.ts:46 (assertPlanOpen): the novel must exist, and a plan at or behind the latest final chapter, or of a final chapter, is canon's history
  private static func open(_ chapter: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> (EntityRef, NovelRecord) {
    let artifact = "chapter:\(chapter)"
    let ref = try handlerDomain(artifact, nil) { () throws(DomainError) in try ChapterRefs.plan(novel: novel, chapter: chapter) }
    let owner = try handlerDomain(artifact, nil) { () throws(DomainError) -> NovelRecord in
      guard case .live(let record) = try transaction.presence(NovelForgeKey.novel(novel), as: NovelRecord.self) else { throw .novelNotFound(novel) }
      return record
    }
    let closed = try handlerDomain(artifact, nil) { () throws(DomainError) in
      let frontier = try transaction.planWorld(novel: novel, chapter: chapter).frontier
      if chapter <= frontier { return true }
      return try transaction.isFinal(novel: novel, chapter: chapter)
    }
    if closed { throw .refused(.planClosed(chapter: chapter)) }
    return (ref, owner)
  }

  private static func planPresence(_ ref: EntityRef, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Presence<ChapterPlanRecord> {
    try handlerDomain("chapter:\(chapter)", ref) { () throws(DomainError) in try transaction.presence(ref, as: ChapterPlanRecord.self) }
  }

  /// One write of `content` as the plan's head: a revision only when it differs from the head the record holds (a restored tombstone's included).
  private static func write(
    _ content: ChapterPlanContent, ref: EntityRef, chapter: Int, over presence: Presence<ChapterPlanRecord>, novel: UUID, in transaction: inout WriteTransaction
  ) throws(ApplyError) {
    let record: ChapterPlanRecord
    do throws(NovelForgeKeyError) {
      record = try ChapterPlanRecord(novel: novel, chapter: chapter, content: content)
    } catch {
      throw .domain(.belowMinimum(field: "chapter", minimum: 1))
    }
    try handlerStore { () throws(StoreError) in
      switch presence {
      case .live(let existing):
        guard !sameRevision(content, existing.content) else { return }
        _ = try ChapterPlanRecord.revise(ref, content, in: &transaction)
      case .removed(let tombstone):
        _ = try tombstone.restore(in: &transaction)
        guard !sameRevision(content, tombstone.content) else { return }
        _ = try ChapterPlanRecord.revise(ref, content, in: &transaction)
      case .absent:
        _ = try record.create(in: &transaction)
      }
    }
  }
}
