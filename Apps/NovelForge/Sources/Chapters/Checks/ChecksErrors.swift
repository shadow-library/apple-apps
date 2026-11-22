import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowCore

enum ChecksErrors {
  static func presented(_ error: ReviewRequestError) -> PresentedError {
    switch error {
    case .review(let review): presented(review)
    case .summary: PresentedError(headline: generic, detail: error.code)
    case .engine(let engine): JobsErrors.presented(engine)
    case .route(let code, _), .model(let code, _): PresentedError(headline: JobsErrors.headline(code: code) ?? generic, detail: code)
    }
  }

  static func presented(_ error: ChapterReviewError) -> PresentedError {
    switch error {
    case .store(let store): PresentedError(store)
    case .domain(let domain): PresentedError(domain) { JobsErrors.headline(code: $0.code) }
    default: PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:251-257
  static func headline(code: String) -> String? {
    switch code {
    case "REV_001": String(localized: "This review is no longer there.", table: "Checks")
    case "REV_002": String(localized: "That finding is not part of this review.", table: "Checks")
    case "REV_003": String(localized: "The chapter changed after this review. Review the current text again before answering its findings.", table: "Checks")
    case "REV_004": String(localized: "Say why you are dismissing this finding.", table: "Checks")
    case "REV_005": String(localized: "Only a blocking finding can be overridden.", table: "Checks")
    case "REV_006": String(localized: "This chapter has no prose to review yet.", table: "Checks")
    case "REV_007": String(localized: "This chapter is still being written. Review it once the draft is ready.", table: "Checks")
    default: nil
    }
  }

  static var generic: String { String(localized: "Something went wrong.", table: "Checks") }
}
