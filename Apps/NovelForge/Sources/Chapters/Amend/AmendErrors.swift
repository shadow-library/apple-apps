import Foundation
import NovelForgeCore
import ShadowCore

enum AmendErrors {
  static func presented(_ error: DomainError) -> PresentedError {
    PresentedError(error) { headline(code: $0.code) }
  }

  static func presented(_ error: ReviewRequestError) -> PresentedError {
    switch error {
    case .summary(.domain(let domain)): presented(domain)
    case .summary(.store(let store)): PresentedError(store)
    case .summary: PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
    case .review(let review): ChecksErrors.presented(review)
    case .engine(let engine): JobsErrors.presented(engine)
    case .route(let code, _), .model(let code, _): PresentedError(headline: headline(code: code) ?? generic, detail: code)
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:19-27,71-74
  static func headline(code: String) -> String? {
    switch code {
    case "CHP_001": String(localized: "This chapter isn't there any more.", table: "Amend")
    case "CHP_006": String(localized: "Only a final chapter can be amended. Approve and finalize this chapter first.", table: "Amend")
    case "CHP_007": String(localized: "This chapter has no prose to summarize yet. Write or import it first.", table: "Amend")
    case "DRF_001": String(localized: "This chapter has no draft to summarize.", table: "Amend")
    case "DRF_013": String(localized: "This chapter changed while it was being summarized. Review the result below, then save it or summarize again.", table: "Amend")
    case "PRJ_001": String(localized: "This novel isn't there any more.", table: "Amend")
    case "domain.empty": String(localized: "This can't be empty.", table: "Amend")
    default: JobsErrors.headline(code: code)
    }
  }

  static var generic: String { String(localized: "Something went wrong.", table: "Amend") }
}
