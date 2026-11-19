import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/refinement/apply/draft.handler.ts, passage-rewrite.ts. Every refusal comes before the first write. The intent changes
// nothing here: apply.types.ts:32 concerns a plan's content mode only.
enum DraftHandlers: ContentOpHandler {
  // draft.handler.ts:134-138
  static func apply(_ operation: ChangeOperation, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    switch operation {
    case .draftUpdate(let update): try write(DraftWrite(update), novel: context.novel, in: &transaction)
    case .draftRemove(let removal): try remove(chapter: removal.chapter, novel: context.novel, in: &transaction)
    case .draftRewritePassage(let rewrite): try rewritePassages(chapter: rewrite.chapter, [rewrite], context: context, in: &transaction)
    default: throw .noHandler(operation.type)
    }
  }

  // draft.handler.ts:114: a chapter's selected rewrites land as one passage_rewritten revision, built from the head this transaction reads, held when they
  // bring in a leak (:129)
  static func rewritePassages(chapter: Int, _ rewrites: [DraftRewritePassage], context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError)
    -> HandlerOutcome
  {
    guard !rewrites.isEmpty else { return HandlerOutcome() }
    let novel = context.novel
    let ref = try draftRef(novel: novel, chapter: chapter)
    try reading(chapter) { () throws(DomainError) in try transaction.requireNovel(novel) }
    let presence = try presence(novel: novel, chapter: chapter, in: transaction)
    try requireAheadOfCanon(novel: novel, chapter: chapter, in: transaction)
    guard case .live(let head) = presence else { throw .domain(.draftNotFound(chapter)) }
    guard !head.content.isolated else { throw .refused(.isolated) }
    let identity: String?
    do throws(StoreError) {
      identity = try DraftIdentity.current(novel: novel, chapter: chapter, in: transaction)
    } catch {
      throw .store(error)
    }
    guard let identity else { throw .unreadable(ref: "draft:\(chapter)") }
    var content = head.content
    do throws(ApplyRefusal) {
      content.body = normalizeLineEndings(try PassageRewrite.rewrittenBody(head.content.body, draftId: identity, chapter: chapter, rewrites))
    } catch {
      throw .refused(error)
    }
    content.source = .known(.passageRewritten)
    content.restoredFrom = nil
    try requireSettledWorkingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction)
    content.leakHeldOver = try PassageLeaks.holdNewLeaks(rewrites, novel: novel, chapter: chapter, in: transaction) ? head.revision : nil
    try commit(content, novel: novel, chapter: chapter, in: &transaction)
    return HandlerOutcome(inverse: DraftWrite(restoring: head.content, chapter: chapter).inverse)
  }

  /// Writes back what an inverse captured (draft.handler.ts:15-34): a restore through the `draft.update` path, a removal through `draft.remove`.
  static func undo(_ inverse: OrderedJSONObject, context: ApplyContext, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let decoded: DraftInverse
    do throws(ApplyRefusal) {
      decoded = try DraftInverse(inverse)
    } catch {
      throw .refused(error)
    }
    switch decoded {
    case .restore(let restore): return try write(restore, novel: context.novel, in: &transaction)
    case .remove(let chapter): return try remove(chapter: chapter, novel: context.novel, in: &transaction)
    }
  }

  /// Commits this device's working copy of each chapter's live, unfinalized draft as its next revision, as the reference's autosave already is when an apply
  /// locks the row (passage-rewrite.spec.ts:514); a copy over a removed draft is kept as a version beside it. Run before the baseline check or an undo's
  /// guard, so the state they compare and the inverse a handler captures include it; a handler refuses a write over a copy left unsettled.
  static func settleWorkingCopies(chapters: [Int], novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) {
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      let presence: DraftPresence
      do throws(ApplyError) {
        presence = try self.presence(novel: novel, chapter: chapter, in: transaction)
      } catch {
        if case .unreadable = error { continue }
        throw error
      }
      if case .removed = presence { try keepWorkingCopyAside(novel: novel, chapter: chapter, ref: try draftRef(novel: novel, chapter: chapter), in: &transaction) }
      guard case .live(let head) = presence, try !reading(chapter, { () throws(DomainError) in try transaction.isFinal(novel: novel, chapter: chapter) }) else { continue }
      do throws(DomainError) {
        _ = try ChapterDrafts.keepWorkingCopy(novel: novel, chapter: chapter, over: head, in: &transaction)
      } catch {
        throw .domain(error)
      }
    }
  }

  static func draftChapters(of ops: [ChangeOp]) -> [Int] {
    ops.compactMap { op in
      switch op.operation {
      case .draftUpdate(let update): update.chapter
      case .draftRemove(let removal): removal.chapter
      case .draftRewritePassage(let rewrite): rewrite.chapter
      default: nil
      }
    }
  }

  // draft.handler.ts:37
  private static func write(_ write: DraftWrite, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let chapter = write.chapter
    let ref = try draftRef(novel: novel, chapter: chapter)
    try reading(chapter) { () throws(DomainError) in try transaction.requireNovel(novel) }
    let presence = try presence(novel: novel, chapter: chapter, in: transaction)
    let entries = try requireAheadOfCanon(novel: novel, chapter: chapter, in: transaction)
    let body = write.body.map(normalizeLineEndings)
    guard case .live(let head) = presence else { return try start(write, body: body, ref: ref, over: presence, entries: entries, novel: novel, in: &transaction) }
    if head.content.isolated, let body, !body.jsEquals(head.content.body) { throw .refused(.isolated) }
    var content = head.content
    content.title = write.title.kept(or: content.title)
    content.body = body ?? content.body
    content.summary = write.summary.kept(or: content.summary)
    content.source = .known(.chatEdited)
    content.restoredFrom = nil
    try requireSettledWorkingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction)
    try commit(content, novel: novel, chapter: chapter, in: &transaction)
    return HandlerOutcome(inverse: DraftWrite(restoring: head.content, chapter: chapter).inverse)
  }

  // draft.handler.ts:45, :59-74: a draft starts only at the next writable chapter, standard and not isolated unless a restore says otherwise
  private static func start(
    _ write: DraftWrite, body: String?, ref: EntityRef, over presence: DraftPresence, entries: [ChapterLifecycleEntry], novel: UUID,
    in transaction: inout WriteTransaction
  ) throws(ApplyError) -> HandlerOutcome {
    let chapter = write.chapter
    guard let body else { throw .refused(.notAllowed) }
    try requireStartsNext(novel: novel, chapter: chapter, entries: entries, in: transaction)
    var content = DraftContent(
      title: write.title.kept(or: nil), body: body, summary: write.summary.kept(or: nil), source: .known(.chatEdited), generator: write.generator ?? .known(.standard),
      isolated: write.isolated ?? false)
    do throws(StoreError) {
      content.upstream = try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
    } catch {
      throw .store(error)
    }
    let record: DraftRecord
    do throws(NovelForgeKeyError) {
      record = try DraftRecord(novel: novel, chapter: chapter, content: content)
    } catch {
      throw .domain(.belowMinimum(field: "chapter", minimum: 1))
    }
    try requireSettledWorkingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction)
    do throws(StoreError) {
      if case .removed = presence {
        _ = try record.restore(in: &transaction)
        _ = try DraftRecord.revise(ref, content, in: &transaction)
      } else {
        _ = try record.create(in: &transaction)
      }
    } catch {
      throw .store(error)
    }
    return HandlerOutcome(inverse: DraftInverse.removal(chapter: chapter))
  }

  // draft.handler.ts:95
  private static func remove(chapter: Int, novel: UUID, in transaction: inout WriteTransaction) throws(ApplyError) -> HandlerOutcome {
    let ref = try draftRef(novel: novel, chapter: chapter)
    guard case .live(let head) = try presence(novel: novel, chapter: chapter, in: transaction) else { throw .domain(.draftNotFound(chapter)) }
    if try reading(chapter, { () throws(DomainError) in try transaction.isFinal(novel: novel, chapter: chapter) }) { throw .refused(.locked) }
    try requireSettledWorkingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction)
    do throws(StoreError) {
      _ = try DraftRecord.remove(ref, in: &transaction)
    } catch {
      throw .store(error)
    }
    return HandlerOutcome(inverse: DraftWrite(restoring: head.content, chapter: chapter).inverse)
  }
}
