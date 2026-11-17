import Foundation
import ShadowCore
import ShadowStore

/// Approving a draft (apps/novel-forge-server/src/modules/generation/generation.service.ts:457). The approval is an appended item naming the revision the author
/// read and the plan terms it was approved under; whether it is in force, across devices, is the lifecycle's derivation (`ChapterFingerprint` rule 6).
public enum ChapterApprovals {
  /// The plan revision of an approval of a chapter without a live plan: revision ids are content hashes, never empty, so it names no plan head.
  public static let planlessRevision = ""

  /// generation.service.ts:457 with its guards in order (DRF_002, DRF_007, DRF_017, DRF_013, PLN_004); the app calls `VaultStore.approveChapter`.
  @discardableResult
  static func approve(
    novel: UUID, chapter: Int, revision: String, as intent: ApprovalIntent = .standard, id: UUID = UUID(), in transaction: inout WriteTransaction
  ) throws(DomainError) -> UUID {
    try transaction.requireNovel(novel)
    let head = try transaction.liveDraft(novel: novel, chapter: chapter)
    guard try !transaction.isFinal(novel: novel, chapter: chapter) else { throw .draftFinal(chapter) }
    let entry = try transaction.lifecycle(novel: novel, chapter: chapter, head: head.revision)
    var kept: StaleCause?
    if case .asWritten = intent { kept = entry.stale }
    if let stale = entry.stale, kept == nil { throw .draftStale(chapter: chapter, reason: stale.reason) }
    if case .reveal? = kept { throw .draftRevealStale(chapter) }
    guard revision.utf8.elementsEqual(head.revision.utf8) else { throw .draftConflict(chapter: chapter, head: head.revision) }
    if case .asWritten(let seen) = intent, let kept, kept != seen { throw .draftConflict(chapter: chapter, head: head.revision) }
    if let verdict = try transaction.revealVerdict(novel: novel, chapter: chapter), verdict.status == .violated {
      throw .planRevealsHeld(chapter: chapter, violations: verdict.reason ?? "")
    }
    let plan = try transaction.planHead(novel: novel, chapter: chapter)
    if entry.review == .approved, let held = entry.approval { return held }
    let approval = ApprovalRecord(
      id: id, novel: novel, chapter: chapter, approvalKind: .known(kept == nil ? .standard : .asWritten), draftRevision: head.revision,
      planRevision: plan?.revision ?? planlessRevision, planTermsDigest: ChapterFingerprint.planTerms(plan?.record.content.contract),
      upstreamDigest: kept == nil ? nil : entry.differences)
    do throws(StoreError) {
      _ = try approval.append(in: &transaction)
      _ = try DraftRecord.mark(head.record.ref, revision: head.revision, [.approved], in: &transaction)
    } catch {
      throw .store(error)
    }
    return id
  }
}
