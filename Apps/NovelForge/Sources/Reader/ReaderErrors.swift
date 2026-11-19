import Foundation
import NovelForgeCore

enum ReaderErrors {
  static func headline(for error: DomainError) -> String? {
    switch error {
    case .novelNotFound: String(localized: "This novel could not be found. It may have been removed on another device.", table: "Reader")
    case .chapterNotFound, .draftNotFound: String(localized: "This chapter has no draft to change. It may have been removed on another device.", table: "Reader")
    case .draftGenerating: String(localized: "This chapter is being written. Wait for it to finish, or stop it.", table: "Reader")
    case .draftFinal: String(localized: "This chapter is final, so its draft can no longer be changed.", table: "Reader")
    case .draftConflict: String(localized: "A newer version of this chapter was saved elsewhere. Choose which text to keep.", table: "Reader")
    case .notNextChapter(_, let next): String(localized: "The next chapter to write is chapter \(next).", table: "Reader")
    case .lifecycleUnavailable: String(localized: "Chapter progress is being rebuilt on this device. Try again in a moment.", table: "Reader")
    case .versionFinal: String(localized: "This chapter is final, so an earlier version cannot be restored.", table: "Reader")
    case .versionNotFound: String(localized: "That version no longer exists.", table: "Reader")
    case .versionUnreadable: String(localized: "That version is stored in a form this version cannot read.", table: "Reader")
    case .unreadable: String(localized: "This chapter is stored in a form this version cannot read.", table: "Reader")
    case .empty, .blank: String(localized: "There is no text to save.", table: "Reader")
    case .belowMinimum: String(localized: "That chapter number is not valid.", table: "Reader")
    default: nil
    }
  }

  static func presented(_ error: any Error) -> PresentedError {
    PresentedError(error, known: headline)
  }
}
