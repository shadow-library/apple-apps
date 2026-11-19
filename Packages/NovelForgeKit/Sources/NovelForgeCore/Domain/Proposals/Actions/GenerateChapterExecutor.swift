import Foundation
import ShadowCore
import ShadowStore

/// apps/novel-forge-server/src/modules/hub/hub-action.registrar.ts:39-45 over `GenerationRequests.jobRequest` (generation.service.ts:224-273): requests the
/// chapter's generate job with the card as its origin; the app's job runtime runs it. A chapter that has a draft is regenerated from the chapter itself (DRF_015).
enum GenerateChapterExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionGenerateChapter(let generate) = action.op.operation else { throw .noHandler(action.op.type) }
    let now = JobActionRequest.requestTime()
    let request: NovelJobRequest
    do throws(GenerationRequestError) {
      request = try GenerationRequests.jobRequest(
        novel: action.novel, chapter: generate.chapter, options: GenerationOptions(), origin: JobActionRequest.origin(of: action)?.json ?? .null, refusingDraft: true, at: now,
        unrestrictedAvailable: UnrestrictedWriting.isAvailable, in: transaction)
    } catch {
      throw JobActionRequest.refusal(error)
    }
    try JobActionRequest.enqueue(request, by: action, at: now, in: &transaction)
    return "enqueued generation of chapter \(generate.chapter)"
  }
}
