import Foundation
import ShadowCore
import ShadowStore
import ShadowText

/// A final chapter's text after finalize: amendments bound to the canon that stands (D06e). The canon, and everything derived from it, never changes.
public enum FinalChapters {
  /// apps/novel-forge-server/src/modules/generation/chapter-amend.service.ts:40: replaces the prose, and the title or note when given; the summary stays.
  /// The reference also passes the text through its markdown sanitizer; this port normalizes line endings only, and readers render markdown safely.
  public static func amend(novel: UUID, chapter: Int, _ amendment: ChapterAmendment, in transaction: inout WriteTransaction) throws(DomainError) {
    guard !amendment.content.isEmpty else { throw .empty(field: "content") }
    let (ref, record) = try final(novel: novel, chapter: chapter, in: transaction)
    var text = record.text
    text.body = normalizeLineEndings(amendment.content)
    if let title = amendment.title { text.title = normalizeLineEndings(title) }
    if let note = amendment.note { text.note = normalizeLineEndings(note) }
    guard !sameText(text, record.text) else { return }
    do throws(StoreError) {
      _ = try FinalChapterRecord.amend(ref, text, in: &transaction)
    } catch {
      throw .store(error)
    }
  }

  /// apps/novel-forge-server/src/modules/generation/draft-save.ts:96 (saveDraftSummary) for a final chapter: the author's own summary, prose untouched.
  public static func editSummary(novel: UUID, chapter: Int, summary: String, in transaction: inout WriteTransaction) throws(DomainError) {
    guard !summary.isEmpty else { throw .empty(field: "summary") }
    let (ref, record) = try final(novel: novel, chapter: chapter, in: transaction)
    guard !sameUnits(record.text.summary, summary) else { return }
    do throws(StoreError) {
      _ = try FinalChapterRecord.editSummary(ref, summary, in: &transaction)
    } catch {
      throw .store(error)
    }
  }

  /// chapter-amend.service.ts:41-47: a chapter that only has a draft or a plan is not final yet (CHP_006); one with nothing is not found (CHP_001).
  private static func final(novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(DomainError) -> (EntityRef, FinalChapterRecord) {
    try transaction.requireNovel(novel)
    let ref = try ChapterRefs.final(novel: novel, chapter: chapter)
    let reading = try storeCall { () throws(StoreError) in try FinalChapterRecord.read(ref, in: transaction) }
    if let entry = try readable(reading, ref: ref) { return (ref, entry.record) }
    guard case .absent = try transaction.draft(novel: novel, chapter: chapter), try transaction.planHead(novel: novel, chapter: chapter) == nil else {
      throw .chapterNotFinal(chapter)
    }
    throw .chapterNotFound(chapter)
  }

  private static func sameText(_ first: FinalChapterText, _ second: FinalChapterText) -> Bool {
    sameUnits(first.title, second.title) && first.body.jsEquals(second.body) && sameUnits(first.note, second.note) && sameUnits(first.summary, second.summary)
  }
}
