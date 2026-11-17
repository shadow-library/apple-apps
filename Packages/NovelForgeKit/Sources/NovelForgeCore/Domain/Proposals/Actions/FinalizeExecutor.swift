import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/hub/hub-action.registrar.ts:96-100: finalizes `upTo`, or the lowest approved chapter, with every refusal of
/// `ChapterFinalize` (generation.service.ts:604).
enum FinalizeExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionFinalize(let finalize) = action.op.operation else { throw .noHandler(action.op.type) }
    let novel = action.novel
    let chapter = try handlerDomain { () throws(DomainError) in try ChapterFinalize.finalize(novel: novel, chapter: finalize.upTo, in: &transaction) }
    // edits this device has not saved over the head the canon froze were never approved; the throw abandons the canon with the action's transaction
    let head = try DraftHandlers.reading(chapter) { () throws(DomainError) in try transaction.liveDraft(novel: novel, chapter: chapter) }
    if try holdsUnsavedEdits(over: head, novel: novel, chapter: chapter, in: transaction) { throw .domain(.draftNotApproved(chapter)) }
    return "finalized chapter \(chapter)"
  }
}
