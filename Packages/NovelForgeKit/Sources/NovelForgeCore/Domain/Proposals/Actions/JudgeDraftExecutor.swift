import Foundation
import ShadowCore
import ShadowJobs
import ShadowStore

/// hub-action.registrar.ts:57-61 over `ReviewRequests.jobRequest` (chapter-review.service.ts:143-154): requests the judge review of the chapter as it stands;
/// the reference runs it inside the action and answers the verdict, here the app's job runtime runs it and the review lands in the chapter's checks.
enum JudgeDraftExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionJudgeDraft(let judge) = action.op.operation else { throw .noHandler(action.op.type) }
    let now = JobActionRequest.requestTime()
    let request: NovelJobRequest
    do throws(ReviewRequestError) {
      request = try ReviewRequests.jobRequest(
        novel: action.novel, chapter: judge.chapter, kind: .judge, unrestricted: false, pace: nil, origin: JobActionRequest.origin(of: action)?.json ?? .null, at: now.date,
        unrestrictedAvailable: UnrestrictedWriting.isAvailable,
        in: JobActionRequest.reading(transaction))
    } catch {
      throw JobActionRequest.refusal(error)
    }
    try JobActionRequest.enqueue(request, by: action, at: now, in: &transaction)
    return "requested a judge review of chapter \(judge.chapter)"
  }
}
