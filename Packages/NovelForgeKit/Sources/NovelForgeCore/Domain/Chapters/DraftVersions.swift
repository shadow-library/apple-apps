import Foundation
import ShadowCore
import ShadowStore

/// A draft's kept revisions (apps/novel-forge-server/src/modules/generation/draft-versions.service.ts).
public enum DraftVersions {
  /// draft-versions.service.ts:43, newest first. The approved version is the one the chapter's latest approval names, as the reference's single
  /// `approved_revision` is; whether that approval is still in force is the lifecycle's to say.
  public static func list<Transaction: StateReading & ~Copyable>(novel: UUID, chapter: Int, in transaction: borrowing Transaction) throws(DomainError) -> [DraftVersion] {
    let ref = try ChapterRefs.draft(novel: novel, chapter: chapter)
    let reading = try storeCall { () throws(StoreError) in try DraftRecord.read(ref, in: transaction) }
    guard let entry = try readable(reading, ref: ref), !entry.isRemoved else { throw .draftNotFound(chapter) }
    guard let history = try storeCall({ () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }).history else { throw .unreadable(ref) }
    let approvals = try storeCall { () throws(StoreError) in try ApprovalRecord.listing(novel: novel, chapter: chapter, in: transaction) }
    let approved = approvals.records.last { $0.approvalKind.known != nil }?.draftRevision
    return history.revisions.map { revision in
      let content = revision.body.body
      return DraftVersion(
        revision: revision.id, source: content?.source, restoredFrom: content?.restoredFrom, isCurrent: revision.id == history.head,
        isApproved: approved.map { $0.utf8.elementsEqual(revision.id.utf8) } ?? false, isolated: content?.isolated ?? false, created: revision.created)
    }
  }

  /// draft-versions.service.ts:76: the old text becomes a new revision through the hand-save path, so it needs approving again; this device's working copy
  /// is kept as a version first. Returns the revision the draft rests on afterwards.
  public static func restore(novel: UUID, chapter: Int, revision: String, base: String?, in transaction: inout WriteTransaction) throws(DomainError) -> String {
    try transaction.requireNovel(novel)
    let live = try transaction.liveDraft(novel: novel, chapter: chapter)
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .versionFinal(chapter) }
    try ChapterDrafts.requireOpen(novel: novel, chapter: chapter, head: live, base: base, in: transaction)
    let ref = live.record.ref
    let history = try storeCall { () throws(StoreError) in try DraftRecord.history(ref, in: transaction) }.history
    guard let target = history?.revisions.first(where: { $0.id.utf8.elementsEqual(revision.utf8) }) else {
      throw .versionNotFound(chapter: chapter, revision: revision)
    }
    guard let restored = target.body.body else { throw .versionUnreadable(chapter: chapter, revision: revision) }
    let head = try ChapterDrafts.keepWorkingCopy(novel: novel, chapter: chapter, over: live, in: &transaction)
    var content = head.content
    content.title = restored.title ?? content.title
    content.body = restored.body
    content.summary = restored.summary
    guard !sameDraftText(content, head.content) else { return head.revision }
    content.isolated = head.content.isolated || restored.isolated
    content.source = .known(.restored)
    content.restoredFrom = target.id
    return try ChapterDrafts.commit(content, novel: novel, chapter: chapter, in: &transaction)
  }
}
