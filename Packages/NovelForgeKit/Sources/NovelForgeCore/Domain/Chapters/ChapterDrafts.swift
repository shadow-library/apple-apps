import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/modules/generation/draft-save.ts:10
public let handEditFoldWindow: TimeInterval = 600

/// The author's own writes to a chapter's draft (apps/novel-forge-server/src/modules/generation/draft-save.ts). Every revision records what it was written
/// against (`DraftUpstream.current`), so later chapters' stale marks and the approval in force follow from it.
public enum ChapterDrafts {
  /// draft-save.ts:55; a save that would fold (draft-save.ts:206) is held in this device's working copy; pass the store's `wallClock()` as `now`.
  public static func save(
    novel: UUID, chapter: Int, _ edit: DraftEdit, base: String?, at now: Date, in transaction: inout WriteTransaction
  ) throws(DomainError) -> DraftSaveOutcome {
    try transaction.requireNovel(novel)
    let body = normalizeLineEndings(edit.body)
    let head: DraftHead
    switch try transaction.draft(novel: novel, chapter: chapter) {
    case .absent, .removed:
      guard base == nil else { throw .draftNotFound(chapter) }
      let content = DraftContent(title: edit.title, body: body, summary: edit.summary, source: .known(.handEdited), generator: .known(.human))
      return .committed(revision: try start(novel: novel, chapter: chapter, content, in: &transaction))
    case .live(let live):
      head = live
    }
    try requireOpen(novel: novel, chapter: chapter, head: head, base: base, in: transaction)
    let copy = try workingCopy(novel: novel, chapter: chapter, over: head, in: &transaction)
    let current = copy?.content ?? head.content
    var updated = current
    updated.title = edit.title ?? current.title
    updated.body = body
    updated.summary = edit.summary ?? current.summary
    guard !sameDraftText(updated, current) else { return copy == nil ? .unchanged(revision: head.revision) : .held(base: head.revision) }
    if base != nil, try foldsIntoHead(head, novel: novel, chapter: chapter, at: now, in: transaction) {
      try held(DraftWorkingCopy(novel: novel, chapter: chapter, base: head.revision, content: updated), in: transaction)
      return .held(base: head.revision)
    }
    var content = head.content
    content.title = updated.title
    content.body = updated.body
    content.summary = updated.summary
    content.source = .known(.handEdited)
    content.restoredFrom = nil
    return .committed(revision: try commit(content, novel: novel, chapter: chapter, in: &transaction))
  }

  /// generation.service.ts:573: pasted prose is never folded; this device's working copy is kept as a version first, so no autosaved text is lost.
  public static func importDraft(novel: UUID, chapter: Int, _ draft: DraftImport, base: String?, in transaction: inout WriteTransaction) throws(DomainError) -> String {
    try transaction.requireNovel(novel)
    let body = normalizeLineEndings(draft.prose)
    guard case .live(let live) = try transaction.draft(novel: novel, chapter: chapter) else {
      guard base == nil else { throw .draftNotFound(chapter) }
      let content = DraftContent(
        title: draft.title, body: body, summary: draft.summary, source: .known(.imported), generator: .known(.human), isolated: draft.isolated ?? false)
      return try start(novel: novel, chapter: chapter, content, in: &transaction)
    }
    try requireOpen(novel: novel, chapter: chapter, head: live, base: base, in: transaction)
    let head = try keepWorkingCopy(novel: novel, chapter: chapter, over: live, in: &transaction)
    var content = head.content
    content.title = draft.title ?? content.title
    content.body = body
    content.summary = draft.summary ?? content.summary
    content.generator = .known(.human)
    content.isolated = draft.isolated ?? content.isolated
    content.source = .known(.imported)
    content.restoredFrom = nil
    return try commit(content, novel: novel, chapter: chapter, in: &transaction)
  }

  /// generation.service.ts:327 ("write it myself"): an empty hand-written draft at the next writable chapter; returns that chapter.
  public static func startNext(novel: UUID, in transaction: inout WriteTransaction) throws(DomainError) -> Int {
    try transaction.requireNovel(novel)
    let chapter = try nextWritableChapter(novel: novel, in: transaction)
    _ = try start(novel: novel, chapter: chapter, DraftContent(body: "", source: .known(.handEdited), generator: .known(.human)), in: &transaction)
    return chapter
  }

  /// Commits this device's working copy as the next revision (on leaving the editor or approving); nil when it holds none, DRF_013 when it is over an old head.
  public static func commitWorkingCopy(novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws(DomainError) -> String? {
    guard let copy = try storeCall({ () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }) else { return nil }
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    try requireOpen(novel: novel, chapter: chapter, head: head, base: copy.base, in: transaction)
    guard !sameDraftText(copy.content, head.content) else {
      try discardWorkingCopy(novel: novel, chapter: chapter, in: transaction)
      return head.revision
    }
    return try commit(copy.content, novel: novel, chapter: chapter, in: &transaction)
  }

  public static func discardWorkingCopy(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) {
    try storeCall { () throws(StoreError) in try DraftWorkingCopy.discard(novel: novel, chapter: chapter, in: transaction.database) }
  }

  /// apps/novel-forge-server/src/common/next-chapter.ts:11, from the lifecycle as reconciled: a chapter with a draft or a canon is written.
  static func nextWritableChapter(novel: UUID, in transaction: borrowing WriteTransaction) throws(DomainError) -> Int {
    guard try !transaction.lifecycleFaulted(novel: novel) else { throw .lifecycleUnavailable(nil) }
    let entries = try transaction.lifecycleEntries(novel: novel)
    return NovelForgeCore.nextWritableChapter(
      draftChapters: entries.filter { $0.draft != nil }.map(\.chapter), finalizedChapters: entries.filter(\.isFinal).map(\.chapter))
  }

  /// draft-save.ts:63-65: a final chapter takes no draft write, and a write made against a revision that is no longer the head is a conflict.
  static func requireOpen(novel: UUID, chapter: Int, head: DraftHead, base: String?, in transaction: borrowing WriteTransaction) throws(DomainError) {
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    if let base, !base.utf8.elementsEqual(head.revision.utf8) { throw .draftConflict(chapter: chapter, head: head.revision) }
  }

  /// Commits the working copy made over `head` before another write replaces the text, and returns the head that write builds on.
  static func keepWorkingCopy(novel: UUID, chapter: Int, over head: DraftHead, in transaction: inout WriteTransaction) throws(DomainError) -> DraftHead {
    guard let copy = try workingCopy(novel: novel, chapter: chapter, over: head, in: &transaction) else { return head }
    guard !sameDraftText(copy.content, head.content) else {
      try discardWorkingCopy(novel: novel, chapter: chapter, in: transaction)
      return head
    }
    _ = try commit(copy.content, novel: novel, chapter: chapter, in: &transaction)
    return try transaction.liveDraft(novel: novel, chapter: chapter)
  }

  /// Writes `content` as the draft's next revision, recording what it rests on; the working copy over the head is superseded, one over an older head kept.
  static func commit(_ content: DraftContent, novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws(DomainError) -> String {
    let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
    _ = try workingCopy(novel: novel, chapter: chapter, over: try transaction.liveDraft(novel: novel, chapter: chapter), in: &transaction)
    var content = content
    let revision: String
    do throws(StoreError) {
      content.upstream = try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
      revision = try DraftRecord.revise(ref, content, in: &transaction).revision
    } catch {
      throw .store(error)
    }
    try discardWorkingCopy(novel: novel, chapter: chapter, in: transaction)
    return revision
  }

  /// draft-save.ts:166 (startDraft): the first draft of the next writable chapter, never over a live one (draft-save.ts:179); a removed draft is restored.
  private static func start(novel: UUID, chapter: Int, _ content: DraftContent, in transaction: inout WriteTransaction) throws(DomainError) -> String {
    let next = try nextWritableChapter(novel: novel, in: transaction)
    guard chapter == next else { throw .notNextChapter(chapter: chapter, next: next) }
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    let presence = try transaction.draft(novel: novel, chapter: chapter)
    if case .live(let head) = presence { throw .draftConflict(chapter: chapter, head: head.revision) }
    let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
    var content = content
    do throws(StoreError) {
      content.upstream = try DraftUpstream.current(novel: novel, chapter: chapter, in: transaction)
      if case .removed = presence {
        _ = try draftRecord(novel: novel, chapter: chapter, content).restore(in: &transaction)
        _ = try DraftRecord.revise(ref, content, in: &transaction)
      } else {
        _ = try draftRecord(novel: novel, chapter: chapter, content).create(in: &transaction)
      }
    } catch {
      throw .store(error)
    }
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    _ = try workingCopy(novel: novel, chapter: chapter, over: head, in: &transaction)
    return head.revision
  }

  private static func draftRecord(novel: UUID, chapter: Int, _ content: DraftContent) throws(StoreError) -> DraftRecord {
    do throws(NovelForgeKeyError) {
      return try DraftRecord(novel: novel, chapter: chapter, content: content)
    } catch {
      throw .invalidChange(error.errorDescription ?? error.code)
    }
  }

  /// draft-save.ts:206 (foldsIntoCurrent): only into the author's own recent hand edit that nobody has approved or marked stale since.
  private static func foldsIntoHead(_ head: DraftHead, novel: UUID, chapter: Int, at now: Date, in transaction: borrowing WriteTransaction) throws(DomainError) -> Bool {
    guard head.content.source.known == .handEdited, now.timeIntervalSince(head.created.date) < handEditFoldWindow else { return false }
    let approvals = try storeCall { () throws(StoreError) in try ApprovalRecord.listing(novel: novel, chapter: chapter, in: transaction) }
    guard !approvals.records.contains(where: { $0.draftRevision.utf8.elementsEqual(head.revision.utf8) }) else { return false }
    guard let entry = try? transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision) else { return false }
    return entry.stale == nil
  }

  /// The working copy over `head`; one made over another revision is first kept as a version beside the head, child of the revision it continued.
  private static func workingCopy(novel: UUID, chapter: Int, over head: DraftHead, in transaction: inout WriteTransaction) throws(DomainError) -> DraftWorkingCopy? {
    let copy = try storeCall { () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }
    guard let copy else { return nil }
    if copy.base.utf8.elementsEqual(head.revision.utf8) { return copy }
    do throws(StoreError) {
      guard case .revisioned(let state)? = try transaction.state(of: head.record.ref, scope: .vault) else { throw .invalidChange("the draft has no revisions") }
      let parent: RevisionParent = state.revisions[ExactString(copy.base)] == nil ? .head : .revision(copy.base)
      _ = try DraftRecord.keep(head.record.ref, copy.content, parent: parent, in: &transaction)
    } catch {
      throw .store(error)
    }
    try discardWorkingCopy(novel: novel, chapter: chapter, in: transaction)
    return nil
  }

  private static func held(_ copy: DraftWorkingCopy, in transaction: borrowing WriteTransaction) throws(DomainError) {
    try storeCall { () throws(StoreError) in try copy.save(in: transaction.database) }
  }
}

/// draft-save.ts:151 compares with `isDeepStrictEqual`: code unit for code unit.
func sameDraftText(_ first: DraftContent, _ second: DraftContent) -> Bool {
  sameUnits(first.title, second.title) && first.body.jsEquals(second.body) && sameUnits(first.summary, second.summary)
}

func sameUnits(_ first: String?, _ second: String?) -> Bool {
  switch (first, second) {
  case (nil, nil): true
  case (let first?, let second?): first.jsEquals(second)
  default: false
  }
}
