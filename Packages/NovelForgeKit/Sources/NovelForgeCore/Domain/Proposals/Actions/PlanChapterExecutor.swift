import Foundation
import OSLog
import ShadowCore
import ShadowStore

/// action-job.service.ts:57-61, :87-101 over `PlanRequests.assess`: requests the plan job of the next writable chapter (PLN_006), one plan at a time (PLN_009),
/// with the card as its origin and the steer checked against the chat's own words; the app's job runtime runs it, and the plan arrives as a card. A card that
/// belongs to no chat has no author words, so a future session-less plan card is refused as `refinement.card_without_chat`.
enum PlanChapterExecutor: ProposalActionExecutor {
  static func execute(_ action: ProposalAction, in transaction: inout WriteTransaction) throws(ApplyError) -> String {
    guard case .actionPlanChapter(let plan) = action.op.operation else { throw .noHandler(action.op.type) }
    guard let origin = JobActionRequest.origin(of: action) else {
      throw .refused(.jobRefused(code: "refinement.card_without_chat", message: "A plan asked for by a card that belongs to no chat has no author words to steer it"))
    }
    let request = ChapterPlanJobRequest(
      novel: action.novel, chapter: plan.chapter, steer: .card(intent: plan.intent, direction: plan.direction, origin: origin), empty: plan.empty ?? false)
    let now = JobActionRequest.requestTime()
    let assessment: PlanAssessment
    do throws(ChapterPlanError) {
      assessment = try PlanRequests.assess(request, at: now, in: JobActionRequest.reading(transaction))
    } catch {
      throw JobActionRequest.refusal(error)
    }
    let chapter = assessment.input.chapter
    if let dropped = assessment.droppedIntent {
      PlanRequests.logger.info(
        "Dropped an intent the author never stated for the direction they chose chapter=\(chapter, privacy: .public) intent=\(dropped, privacy: .private)")
    }
    if assessment.open != nil { return "chapter \(chapter) is already being planned" }
    try JobActionRequest.enqueue(assessment.jobRequest(for: request), by: action, at: now, in: &transaction)
    return "planning chapter \(chapter) — the plan arrives as a card"
  }
}
