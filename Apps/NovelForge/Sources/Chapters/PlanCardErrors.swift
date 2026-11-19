import Foundation
import NovelForgeCore
import ShadowCore

/// What a plan card's refused save shows: a title and the one thing the author can do about it.
struct PlanCardNotice: Equatable {
  let title: String
  let message: String?
}

/// Headlines for a refused plan request, and the plan card's own words for a refused save; the job codes reuse `JobsErrors`.
enum PlanCardErrors {
  static func presented(_ error: ChapterPlanError) -> PresentedError {
    switch error {
    case .engine(let engine): JobsErrors.presented(engine)
    case .store(let store): PresentedError(store)
    default: PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:40-43; PLN_009, JOB_002 and AI_024 (a plan job's run refused by its route) read as JobsErrors says
  static func headline(code: String) -> String? {
    switch code {
    case "PLN_006": String(localized: "Only the next chapter can be planned, and the story has moved on. Plan the chapter that's next now.", table: "PlanCard")
    case "PLN_007": String(localized: "This chapter already has a plan, so an empty one can't replace it.", table: "PlanCard")
    case "chapters.lifecycle_unavailable":
      String(localized: "Which chapter comes next can't be read on this device right now. Try again after syncing.", table: "PlanCard")
    case "plan.jobs_unavailable":
      String(localized: "Whether a plan is already being made can't be read on this device right now. Try again after syncing.", table: "PlanCard")
    case "plan.steering_unavailable": String(localized: "Your direction couldn't be read on this device. Try again without it.", table: "PlanCard")
    default: JobsErrors.headline(code: code)
    }
  }

  /// apps/novel-forge-web/src/lib/plan-card.ts:337-357; the reference's PLN_001 and PLN_003 offer edits to the card, which this version cannot make.
  static func notice(_ notice: ChatCardNotice) -> PlanCardNotice {
    switch notice.error.detail {
    case "PLN_008":
      PlanCardNotice(
        title: String(localized: "The story has moved on", table: "PlanCard"),
        message: String(localized: "This plan is for a chapter that is no longer next. Plan the next chapter again.", table: "PlanCard"))
    case "RFN_002":
      PlanCardNotice(
        title: String(localized: "This plan was already used or discarded", table: "PlanCard"),
        message: String(localized: "It can no longer change. Ask for a new plan if you need one.", table: "PlanCard"))
    case "PLN_001":
      PlanCardNotice(
        title: String(localized: "A reveal in this plan isn't unlocked here", table: "PlanCard"),
        message: String(localized: "Claim the milestone it waits for, or plan the chapter again.", table: "PlanCard"))
    case "PLN_003":
      PlanCardNotice(
        title: String(localized: "A milestone can't be claimed here", table: "PlanCard"),
        message: String(localized: "Plan the chapter again without it.", table: "PlanCard"))
    default:
      PlanCardNotice(title: notice.error.headline, message: nil)
    }
  }

  private static var generic: String { String(localized: "Something went wrong.", table: "PlanCard") }
}
