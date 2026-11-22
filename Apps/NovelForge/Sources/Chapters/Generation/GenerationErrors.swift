import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowStore

enum GenerationErrors {
  static func presented(_ error: GenerationRequestError) -> PresentedError {
    switch error {
    case .engine(let engine): JobsErrors.presented(engine)
    case .domain(let domain): presented(domain)
    case .outOfOrder(let chapter, let blocker): PresentedError(headline: outOfOrder(chapter, blocker), detail: error.code)
    case .externalChapter(_, let blocker):
      PresentedError(headline: String(localized: "Chapter \(blocker) is written outside Novel Forge. Fill it in and finalize it first.", table: "Generation"), detail: error.code)
    case .teacherUnsettled(_, let teacher):
      PresentedError(
        headline: String(localized: "Chapter \(teacher) has to settle what its characters learn before this chapter can be written.", table: "Generation"), detail: error.code)
    case .planMissing, .planStale, .chapterLocked, .draftExists, .generationRunning, .contradiction, .route:
      PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
    }
  }

  static func presented(_ error: DomainError) -> PresentedError {
    PresentedError(error) { headline(code: $0.code) ?? ReaderErrors.headline(for: $0) }
  }

  static func presented(_ error: any Error) -> PresentedError {
    switch error {
    case let request as GenerationRequestError: presented(request)
    case let domain as DomainError: presented(domain)
    default: PresentedError(error)
    }
  }

  static func headline(code: String) -> String? {
    switch code {
    case "BRF_001": String(localized: "This chapter has no plan yet. Plan it before writing it.", table: "Generation")
    case "BRF_002": String(localized: "This chapter's plan is out of date. Refresh the plan before writing it.", table: "Generation")
    case "CHP_008": String(localized: "This chapter is final. Its text changes only through an amendment.", table: "Generation")
    case "DRF_015": String(localized: "This chapter already has a draft. Regenerate it from the chapter itself.", table: "Generation")
    default: JobsErrors.headline(code: code)
    }
  }

  private static func outOfOrder(_ chapter: Int, _ blocker: Int?) -> String {
    guard let blocker else { return String(localized: "Chapter \(chapter) can't be written yet. Chapters are written in order.", table: "Generation") }
    return String(localized: "Chapter \(chapter) can't be written before chapter \(blocker) has a draft. Chapters are written in order.", table: "Generation")
  }

  private static var generic: String { String(localized: "Something went wrong.", table: "Generation") }
}
