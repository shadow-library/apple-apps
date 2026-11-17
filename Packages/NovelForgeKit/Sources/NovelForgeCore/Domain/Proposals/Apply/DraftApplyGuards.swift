import Foundation
import ShadowCore
import ShadowStore

extension DraftHandlers {
  /// Reads that refuse with a `DomainError`, which an apply carries as is; a draft this version cannot read is never taken for a missing one.
  static func reading<T>(_ chapter: Int, _ body: () throws(DomainError) -> T) throws(ApplyError) -> T {
    do throws(DomainError) {
      return try body()
    } catch {
      if case .unreadable = error { throw .unreadable(ref: "draft:\(chapter)") }
      throw .domain(error)
    }
  }

  static func presence(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> DraftPresence {
    try reading(chapter) { () throws(DomainError) in try transaction.draft(novel: novel, chapter: chapter) }
  }

  /// draft.handler.ts:40, :44, :120, :124: a final chapter, or one at or behind the story cursor, is canon (RFN_010). The cursor is the latest final chapter
  /// as the lifecycle reconciled it, as a plan write's (PLN_005); the chapter's own canon is read from its record. Returns the lifecycle it read.
  @discardableResult
  static func requireAheadOfCanon(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> [ChapterLifecycleEntry] {
    let (entries, locked) = try reading(chapter) { () throws(DomainError) -> ([ChapterLifecycleEntry], Bool) in
      guard try !transaction.lifecycleFaulted(novel: novel) else { throw .lifecycleUnavailable(chapter) }
      let entries = try transaction.lifecycleEntries(novel: novel)
      if chapter <= entries.filter(\.isFinal).map(\.chapter).max() ?? 0 { return (entries, true) }
      return (entries, try transaction.isFinal(novel: novel, chapter: chapter))
    }
    if locked { throw .refused(.locked) }
    return entries
  }

  /// apps/novel-forge-server/src/common/next-chapter.ts:18 over the drafts as this transaction leaves them: `entries` is the lifecycle reconciled at its
  /// start, so a draft an earlier change of the same apply created or removed is read from its record.
  static func requireStartsNext(novel: UUID, chapter: Int, entries: [ChapterLifecycleEntry], in transaction: borrowing WriteTransaction) throws(ApplyError) {
    try reading(chapter) { () throws(DomainError) in
      var drafts = Set(entries.filter { $0.draft != nil }.map(\.chapter))
      for written in try draftChaptersWritten(novel: novel, in: transaction) {
        if case .live = try transaction.draft(novel: novel, chapter: written) { drafts.insert(written) } else { drafts.remove(written) }
      }
      do throws(NextChapterError) {
        try assertStartsNextChapter(chapter, draftChapters: Array(drafts), finalizedChapters: entries.filter(\.isFinal).map(\.chapter))
      } catch {
        switch error {
        case .notNextChapter(let chapter, let next): throw .notNextChapter(chapter: chapter, next: next)
        }
      }
    }
  }

  private static func draftChaptersWritten(novel: UUID, in transaction: borrowing WriteTransaction) throws(DomainError) -> Set<Int> {
    var chapters = Set<Int>()
    for change in transaction.changes where change.entity == NovelForgeKind.draft.entityKind {
      let ref = EntityRef(kind: change.entity, key: change.key)
      guard let state = try storeCall({ () throws(StoreError) in try transaction.state(of: ref, scope: .vault) }),
        let key = try? NovelForgeKey(reading: state, of: ref), key.novel == novel, case .draft(let chapter) = key.components
      else { continue }
      chapters.insert(chapter)
    }
    return chapters
  }

  /// Refuses a write over unsaved text: the working copy this device holds for the chapter must be settled first, unless it holds the head's own text over
  /// the head, when it is dropped.
  static func requireSettledWorkingCopy(novel: UUID, chapter: Int, ref: EntityRef, in transaction: borrowing WriteTransaction) throws(ApplyError) {
    let held: (copy: DraftWorkingCopy, revisions: Set<ExactString>, holdsHead: Bool)?
    do throws(StoreError) {
      held = try workingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction)
    } catch {
      throw .store(error)
    }
    guard let held else { return }
    guard held.holdsHead else { throw .refused(.unsettledWorkingCopy(chapter: chapter)) }
    do throws(StoreError) {
      try DraftWorkingCopy.discard(novel: novel, chapter: chapter, in: transaction.database)
    } catch {
      throw .store(error)
    }
  }

  /// D23's orphan rule for a removed draft: the copy is kept as a version beside the head, child of the revision it continued, then dropped.
  static func keepWorkingCopyAside(novel: UUID, chapter: Int, ref: EntityRef, in transaction: inout WriteTransaction) throws(ApplyError) {
    do throws(StoreError) {
      guard let held = try workingCopy(novel: novel, chapter: chapter, ref: ref, in: transaction) else { return }
      if !held.holdsHead {
        let parent: RevisionParent = held.revisions.contains(ExactString(held.copy.base)) ? .revision(held.copy.base) : .head
        _ = try DraftRecord.keep(ref, held.copy.content, parent: parent, in: &transaction)
      }
      try DraftWorkingCopy.discard(novel: novel, chapter: chapter, in: transaction.database)
    } catch {
      throw .store(error)
    }
  }

  private static func workingCopy(novel: UUID, chapter: Int, ref: EntityRef, in transaction: borrowing WriteTransaction) throws(StoreError) -> (
    copy: DraftWorkingCopy, revisions: Set<ExactString>, holdsHead: Bool
  )? {
    guard let copy = try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) else { return nil }
    guard case .revisioned(let state)? = try transaction.state(of: ref, scope: .vault), let head = state.headRevision else { return (copy, [], false) }
    let headContent = state.revisions[ExactString(head)].flatMap { DraftContent(json: $0.body) }
    let holdsHead = copy.base.utf8.elementsEqual(head.utf8) && headContent.map { sameDraftText(copy.content, $0) } == true
    return (copy, Set(state.revisions.keys), holdsHead)
  }

  static func commit(_ content: DraftContent, novel: UUID, chapter: Int, in transaction: inout WriteTransaction) throws(ApplyError) {
    do throws(DomainError) {
      _ = try ChapterDrafts.commit(content, novel: novel, chapter: chapter, in: &transaction)
    } catch {
      throw .domain(error)
    }
  }

  static func draftRef(novel: UUID, chapter: Int) throws(ApplyError) -> EntityRef {
    try reading(chapter) { () throws(DomainError) in try ChapterRefs.draft(novel: novel, chapter: chapter) }
  }
}
