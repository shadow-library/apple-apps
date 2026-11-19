import Foundation
import ShadowCore
import ShadowStore

/// A selected action of an applied card, run after the card's content committed (proposal-apply.service.ts:224-226).
struct ProposalAction: Sendable {
  let proposal: ProposalRecord
  let index: Int
  let op: ChangeOp
  /// The replica applying the card, which requests any job the action asks for.
  let requester: ReplicaID

  var novel: UUID { proposal.novel }
}

/// apps/novel-forge-server/src/modules/refinement/action-registry.ts:21: an executor reads every record it needs and throws before its first write; it
/// returns the summary its change settles with.
protocol ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String
}

// action-registry.ts:27: an action with no executor reads "not yet available" and keeps its card's apply refused
public enum ProposalActionRegistry {
  public static func isRunnable(_ type: OpType) -> Bool { executor(for: type) != nil }

  static func executor(for type: OpType) -> (any ProposalActionExecutor.Type)? {
    switch type {
    case .actionApproveDraft: ApproveDraftExecutor.self
    case .actionFinalize: FinalizeExecutor.self
    case .actionAdvanceVolume: AdvanceVolumeExecutor.self
    case .actionGenerateChapter: GenerateChapterExecutor.self
    case .actionPlanChapter: PlanChapterExecutor.self
    case .actionJudgeDraft: JudgeDraftExecutor.self
    default: nil
    }
  }
}

/// Whether this device holds edits over `head` it has not saved: approving or finalizing the head would bind text the author no longer sees. A copy with the
/// head's own text changes nothing.
func holdsUnsavedEdits(over head: DraftHead, novel: UUID, chapter: Int, in transaction: borrowing WriteTransaction) throws(ApplyError) -> Bool {
  let copy = try handlerStore { () throws(StoreError) in try DraftWorkingCopy.read(novel: novel, chapter: chapter, in: transaction.database) }
  guard let copy, copy.base.utf8.elementsEqual(head.revision.utf8) else { return false }
  return !sameDraftText(copy.content, head.content)
}
