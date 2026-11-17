import Foundation
import ShadowCore
import ShadowStore

// The server-stamped members of a staged change set: apps/novel-forge-server/src/modules/refinement/proposal.service.ts:96-123
enum ProposalStamps {
  /// proposal.service.ts:97 at staging: `startedEmpty` is server-only, so it is dropped from whatever arrives.
  static func withoutStartedEmpty(_ ops: [ChangeOp]) -> [ChangeOp] {
    ops.map { op in
      var metadata = op.metadata
      metadata.startedEmpty = nil
      return ChangeOp(operation: op.operation, metadata: metadata)
    }
  }

  /// proposal.service.ts:106 with `keepSupplied` false: an approval binds to the draft as it stands at staging, whatever revision a model sent; a chapter with
  /// no draft this device can read leaves the approval unstamped, which the apply refuses (hub-action.registrar.ts:72, DRF_013).
  static func approvalRevisions(_ ops: [ChangeOp], stamps: [Int: ApprovalStamp]) -> [ChangeOp] {
    ops.map { op in
      guard case .actionApproveDraft(var approval) = op.operation else { return op }
      let stamp = stamps[approval.chapter]
      approval.revision = stamp?.generation
      approval.saveSeq = stamp.map { _ in 0 }
      approval.draftId = stamp?.draftId
      return ChangeOp(operation: .actionApproveDraft(approval), metadata: op.metadata)
    }
  }

  static func approvalChapters(_ ops: [ChangeOp]) -> [Int] {
    ops.compactMap { op in
      guard case .actionApproveDraft(let approval) = op.operation else { return nil }
      return approval.chapter
    }
  }

  /// The heads approvals bind to, read once this device's working copies of those chapters are committed, as approving from the editor commits them first
  /// (`VaultStore.approveChapter`); a draft this device cannot read is left out, so its approval stays unstamped.
  static func approvalStamps(_ chapters: [Int], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalStagingError) -> [Int: ApprovalStamp] {
    var stamps = [Int: ApprovalStamp]()
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      do throws(ApplyError) {
        guard case .live(let head) = try DraftHandlers.presence(novel: novel, chapter: chapter, in: transaction) else { continue }
        let (identity, generation) = try identity(of: head, chapter: chapter, novel: novel, in: transaction)
        stamps[chapter] = ApprovalStamp(draftId: "\(identity)/\(head.revision)", generation: generation)
      } catch {
        if case .unreadable = error { continue }
        throw .draft(error)
      }
    }
    return stamps
  }

  /// An approval binds the version the author sees: a working copy this device holds over an earlier head would be kept aside by the settle while the approval
  /// bound the head another device wrote, so it is refused, as approving from the editor refuses a revision that is not the head.
  static func requireCopiesOverHeads(_ chapters: [Int], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalStagingError) {
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      let copy: DraftWorkingCopy?
      do throws(StoreError) {
        copy = try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database)
      } catch {
        throw .store(error)
      }
      guard let copy else { continue }
      let presence: DraftPresence
      do throws(ApplyError) {
        presence = try DraftHandlers.presence(novel: novel, chapter: chapter, in: transaction)
      } catch {
        if case .unreadable = error { continue }
        throw .draft(error)
      }
      if case .live(let head) = presence, !copy.base.utf8.elementsEqual(head.revision.utf8) { throw .approvalOverMovedDraft(chapter: chapter) }
    }
  }

  /// passage-rewrite.ts:146: the live drafts rewrites are anchored to, read through this device's working copies, with whether each is canon; a draft this
  /// device cannot read refuses the staging.
  static func rewriteDrafts(_ chapters: [Int], novel: UUID, in transaction: borrowing WriteTransaction) throws(ProposalStagingError) -> [Int: AnchorDraft] {
    var drafts = [Int: AnchorDraft]()
    for chapter in Set(chapters).sorted() where chapter >= 1 {
      do throws(ApplyError) {
        if let draft = try anchorDraft(chapter, novel: novel, in: transaction) { drafts[chapter] = draft }
      } catch {
        throw .draft(error)
      }
    }
    return drafts
  }

  private static func anchorDraft(_ chapter: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> AnchorDraft? {
    guard case .live(let head) = try DraftHandlers.presence(novel: novel, chapter: chapter, in: transaction) else { return nil }
    let (identity, generation) = try identity(of: head, chapter: chapter, novel: novel, in: transaction)
    let content = try DraftReadThrough.content(novel: novel, chapter: chapter, over: head, in: transaction)
    var locked = false
    do throws(ApplyError) {
      try DraftHandlers.requireAheadOfCanon(novel: novel, chapter: chapter, in: transaction)
    } catch {
      guard case .refused(.locked) = error else { throw error }
      locked = true
    }
    return AnchorDraft(id: identity, revision: generation, saveSeq: 0, body: content.body, isolated: content.isolated, locked: locked)
  }

  private static func identity(of head: DraftHead, chapter: Int, novel: UUID, in transaction: borrowing WriteTransaction) throws(ApplyError) -> (String, Int) {
    let ref = try DraftHandlers.draftRef(novel: novel, chapter: chapter)
    let state: EntityState?
    do throws(StoreError) {
      state = try transaction.state(of: ref, scope: .vault)
    } catch {
      throw .store(error)
    }
    guard let identity = DraftIdentity.of(state), case .revisioned(let revisioned)? = state,
      let generation = revisioned.revisions[ExactString(head.revision)]?.generation, let revision = Int(exactly: generation)
    else { throw .unreadable(ref: "draft:\(chapter)") }
    return (identity, revision)
  }
}

/// What an approval op is stamped with: `draftId` names the draft's life (`DraftIdentity`) and its exact head revision as `<identity>/<revision id>`, so the
/// apply binds that revision and nothing else; `revision` carries the head's generation and `saveSeq` 0 only because the reference's executor requires both
/// (hub-action.registrar.ts:72).
struct ApprovalStamp: Sendable, Equatable {
  let draftId: String
  let generation: Int
}
