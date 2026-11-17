import Foundation
import ShadowCore
import ShadowStore

extension VaultStore {
  /// Approves what the author read (orchestrator decision 6): this device's working copy over `revision` is committed first, in a write of its own, because
  /// the approval's guards read the lifecycle, which knows a head only once it is committed. Returns the approval in force afterwards.
  @discardableResult
  public func approveChapter(novel: UUID, chapter: Int, revision: String, as intent: ApprovalIntent = .standard, id: UUID = UUID()) async throws(DomainError) -> UUID {
    let committed = try await writeDomain { transaction throws(DomainError) -> String? in
      let copy = try storeCall { () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }
      guard let copy, copy.base.utf8.elementsEqual(revision.utf8) else { return nil }
      return try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: chapter, in: &transaction)
    }
    return try await writeDomain { transaction throws(DomainError) in
      try ChapterApprovals.approve(novel: novel, chapter: chapter, revision: committed ?? revision, as: intent, id: id, in: &transaction)
    }
  }
}
