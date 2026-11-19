import Foundation
import NovelForgeCore

/// Headlines for what approve, the finalize review's answers and finalize refuse (apps/novel-forge-server/src/classes/app-error-code.ts:17-84, 295-311); the
/// job codes a read surfaces keep `JobsErrors`' words.
enum FinalizeErrors {
  static func presented(_ error: any Error) -> PresentedError {
    if let answer = error as? FinalizeAnswerError { return presented(answer) }
    return PresentedError(error) { headline(for: $0) }
  }

  static func presented(_ error: FinalizeAnswerError) -> PresentedError {
    if case .domain(let domain) = error { return presented(domain) }
    return PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
  }

  static func headline(for domain: DomainError) -> String? {
    switch domain {
    case .finalizeRefused(let refusal): headline(for: refusal)
    case .draftStale(let chapter, _):
      String(localized: "Chapter \(chapter) is out of date: something it was written against changed. Edit it, or approve it as written.", table: "Finalize")
    case .summaryMissing(let chapter): String(localized: "Chapter \(chapter) has no summary. Write one or summarize it first.", table: "Finalize")
    case .planRevealsHeld(let chapter, _): String(localized: "The plan for chapter \(chapter) reveals something too early. Fix the plan first.", table: "Finalize")
    default: headline(code: domain.code)
    }
  }

  static func headline(for refusal: FinalizeRefusal) -> String {
    switch refusal {
    case .openBlockingFindings(_, let count):
      String(localized: "\(count) blocking findings are still open. Change the text, dismiss them or approve over them first.", table: "Finalize")
    case .reviewPreparing: String(localized: "The Story Bible updates are still being read from the approved version. Finalize once they are ready.", table: "Finalize")
    case .reviewFailed: String(localized: "Reading the Story Bible updates from this chapter failed. Read them again.", table: "Finalize")
    case .proseChanged: String(localized: "The text changed since you approved it, so its Story Bible updates no longer apply. Approve it again.", table: "Finalize")
    case .unanswered(let count): String(localized: "\(count) Story Bible updates still need your call.", table: "Finalize")
    case .strandedReveal(let milestone, let facts): stranded(milestone: milestone, facts: facts.joined(separator: ", "))
    case .isolatedByAuthorOnly(let chapter): String(localized: "Chapter \(chapter) is isolated, so only you can finalize it.", table: "Finalize")
    }
  }

  /// finalize-refusals.ts:35-46 through FinalizeReadiness, in its order; one headline per reason finalize refuses the chapter now.
  static func headline(for blocker: FinalizeBlocker) -> String {
    switch blocker {
    case .draftNotFound: String(localized: "This chapter has no draft to finalize.", table: "Finalize")
    case .draftUnreadable: String(localized: "This chapter's draft is stored in a form this version cannot read.", table: "Finalize")
    case .draftFinal(let chapter): String(localized: "Chapter \(chapter) is already final.", table: "Finalize")
    case .notApproved(let chapter): String(localized: "Chapter \(chapter) isn't approved. Approve it first.", table: "Finalize")
    case .stale(let chapter, _):
      String(localized: "Chapter \(chapter) is out of date: something it was written against changed. Edit it, or approve it as written.", table: "Finalize")
    case .openBlockingFindings(let chapter, let count): headline(for: FinalizeRefusal.openBlockingFindings(chapter: chapter, count: count))
    case .reviewPreparing: headline(for: FinalizeRefusal.reviewPreparing(chapter: 0))
    case .proseChanged: headline(for: FinalizeRefusal.proseChanged)
    case .unanswered(let count): headline(for: FinalizeRefusal.unanswered(count: count))
    case .strandedReveal(let milestone, let facts): headline(for: FinalizeRefusal.strandedReveal(milestone: milestone, facts: facts))
    case .notFinalizable(let chapter): String(localized: "Chapter \(chapter) is isolated and needs its summary and where things stand before it can be final.", table: "Finalize")
    case .summaryMissing(let chapter): String(localized: "Chapter \(chapter) has no summary. Write one or summarize it first.", table: "Finalize")
    case .planReveals(let chapter, _): String(localized: "The plan for chapter \(chapter) reveals something too early. Fix the plan first.", table: "Finalize")
    case .outOfOrder: String(localized: "Chapters are finalized in order. Finalize the earlier chapters first.", table: "Finalize")
    }
  }

  // app-error-code.ts:17-84, 295-311
  static func headline(code: String) -> String? {
    switch code {
    case "DRF_001": String(localized: "This chapter has no draft. It may have been removed on another device.", table: "Finalize")
    case "DRF_002": String(localized: "This chapter is already final.", table: "Finalize")
    case "DRF_004": String(localized: "This chapter isn't approved. Approve it first.", table: "Finalize")
    case "DRF_013": String(localized: "This chapter changed or is being written. Read the version on screen, then approve again.", table: "Finalize")
    case "DRF_017": String(localized: "A reveal in this chapter's plan no longer holds, so it can't be approved as written. Fix the plan first.", table: "Finalize")
    case "CHP_005": String(localized: "This isolated chapter needs its summary and where things stand before it can be final.", table: "Finalize")
    case "FIN_001": String(localized: "Chapters are finalized in order. Finalize the earlier chapters first.", table: "Finalize")
    case "FRV_001": String(localized: "This chapter has no Story Bible review yet. Approve it first.", table: "Finalize")
    case "FRV_004": headline(for: FinalizeRefusal.proseChanged)
    case "FRV_008": String(localized: "That update is no longer part of this review.", table: "Finalize")
    case "FRV_009": String(localized: "An edited update keeps its kind and the record it is about. Change only its details.", table: "Finalize")
    case "FRV_010": String(localized: "Say why you're skipping this update.", table: "Finalize")
    case "FRV_011": String(localized: "These updates were already applied when the chapter was finalized.", table: "Finalize")
    case "chapters.approval_overrides_unconfirmed":
      String(localized: "A check arrived with more blocking findings than you confirmed. Approve again to see them.", table: "Finalize")
    case "chapters.lifecycle_unavailable": String(localized: "Chapter progress is being rebuilt on this device. Try again in a moment.", table: "Finalize")
    case "domain.unreadable": String(localized: "Part of this chapter is stored in a form this version cannot read.", table: "Finalize")
    default: JobsErrors.headline(code: code)
    }
  }

  private static func stranded(milestone: String, facts: String) -> String {
    String(localized: "This chapter reveals \(facts), which needs milestone \(milestone). Keep the milestone as reached, or change the plan or the text.", table: "Finalize")
  }

  private static var generic: String { String(localized: "Something went wrong.", table: "Finalize") }
}
