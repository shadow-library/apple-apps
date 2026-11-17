import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/hub/hub-action.registrar.ts:69-78 and proposal-apply.service.ts:58 (bindApprovalRevision). The approval names exactly
/// one revision: the head the card's own applied change wrote, when it wrote this draft, else the revision the card was staged against.
enum ApproveDraftExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionApproveDraft(let approval) = action.op.operation else { throw .noHandler(action.op.type) }
    let novel = action.novel
    let chapter = approval.chapter
    let head = try DraftHandlers.reading(chapter) { () throws(DomainError) in try transaction.liveDraft(novel: novel, chapter: chapter) }
    try requireCopyOverHead(head, novel: novel, chapter: chapter, in: transaction)
    // generation.service.ts:463 (DRF_013): the revision approved is the one the author sees
    guard try binds(approval, head: head, action: action, in: transaction), try !holdsUnsavedEdits(over: head, novel: novel, chapter: chapter, in: transaction) else {
      throw .domain(.draftConflict(chapter: chapter, head: head.revision))
    }
    try handlerDomain { () throws(DomainError) in
      _ = try ChapterApprovals.approve(novel: novel, chapter: chapter, revision: head.revision, in: &transaction)
    }
    return "approved chapter \(chapter)'s draft"
  }

  /// An approval binds the version the author sees: this device's unsaved edits over an earlier head would be kept aside once settled, so the approval of
  /// the head another device wrote is refused, as staging it is.
  private static func requireCopyOverHead(_ head: DraftHead, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) {
    let copy = try handlerStore { () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }
    if let copy, !copy.base.utf8.elementsEqual(head.revision.utf8) { throw .refused(.approvalOverMovedDraft(chapter: chapter)) }
  }

  private static func binds(_ approval: ApproveDraftAction, head: DraftHead, action: ProposalAction, in transaction: borrowing WriteTransaction) throws(ApplyError)
    -> Bool
  {
    let ref = "draft:\(approval.chapter)"
    if let written = try writtenState(ref, of: action, in: transaction) {
      let current = try handlerStore { () throws(StoreError) in try ArtifactStateLoader.states(refs: [ref], novel: action.novel, in: transaction) }
      return current[JSString(ref)].map(written.matches) ?? false
    }
    // hub-action.registrar.ts:72 without its /^\d+$/ check: the stamp is `<identity>/<revision id>`, split at the last "/"
    guard approval.revision != nil, approval.saveSeq != nil, let draftId = approval.draftId, let slash = draftId.lastIndex(of: "/") else { return false }
    let identity = draftId[..<slash]
    let revision = draftId[draftId.index(after: slash)...]
    let current = try handlerStore { () throws(StoreError) in try DraftIdentity.current(novel: action.novel, chapter: approval.chapter, in: transaction) }
    guard let current else { return false }
    return identity.utf8.elementsEqual(current.utf8) && revision.utf8.elementsEqual(head.revision.utf8)
  }

  /// The state the card's own applied change left the draft in, read from its stored undo, so a resumed action binds it as the first run would have; the
  /// head is matched by content, since the revision id it wrote is not stored.
  private static func writtenState(_ ref: String, of action: ProposalAction, in transaction: borrowing WriteTransaction) throws(ApplyError) -> ArtifactState? {
    let entries = try handlerStore { () throws(StoreError) in try ProposalChangeRecord.changes(of: action.proposal, in: transaction) }
    let written = entries.compactMap { entry -> ArtifactState? in
      guard case .recorded(let change) = entry, change.index != action.index else { return nil }
      return change.undo?.postState[ref]
    }
    return written.last
  }
}
