import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/hub/hub-action.registrar.ts:96-100: the author's accepted card finalizes `upTo`, or the lowest approved chapter, through
/// the same gate and commit as `ChapterFinalize` (generation.service.ts:583-602), its canon_refresh request carrying the card as its origin
/// (actions/action-jobs.ts:27-30).
enum FinalizeExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionFinalize(let finalize) = action.op.operation else { throw .noHandler(action.op.type) }
    let (novel, origin) = (action.novel, origin(of: action))
    let chapter = try handlerDomain { () throws(DomainError) in
      try ChapterFinalize.finalize(novel: novel, chapter: finalize.upTo, by: .author, origin: origin, in: &transaction)
    }
    // edits this device has not saved over the head the canon froze were never approved; the throw abandons the canon with the action's transaction
    let head = try DraftHandlers.reading(chapter) { () throws(DomainError) in try transaction.liveDraft(novel: novel, chapter: chapter) }
    if try holdsUnsavedEdits(over: head, novel: novel, chapter: chapter, in: transaction) { throw .domain(.draftNotApproved(chapter)) }
    return "finalized chapter \(chapter)"
  }

  private static func origin(of action: ProposalAction) -> JSONValue {
    guard let session = action.proposal.card.session else { return .null }
    return NovelJobOrigin.json(session: session, message: action.proposal.card.message, proposal: action.proposal.id, opIndex: action.index)
  }
}
