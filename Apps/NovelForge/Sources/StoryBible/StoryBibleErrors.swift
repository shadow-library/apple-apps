import Foundation
import NovelForgeCore
import ShadowAppShell

enum StoryBibleErrors {
  static func presented(_ error: any Error) -> PresentedError {
    guard let issue = error as? BibleWriteIssue else { return PresentedError(error, known: headline) }
    switch issue {
    case .pageChanged:
      return PresentedError(
        headline: String(
          localized: "This page changed after you opened it. Save again to replace it with your version; the other version stays in its history.", table: "StoryBible"),
        detail: nil)
    }
  }

  static func headline(for error: DomainError) -> String? {
    switch error {
    case .entityExists: String(localized: "An entry with this key already exists. Choose another key.", table: "StoryBible")
    case .entityNotFound: String(localized: "This entry could not be found. It may have been removed.", table: "StoryBible")
    case .documentNotFound: String(localized: "This page could not be found. It may have been removed.", table: "StoryBible")
    case .documentExists: String(localized: "A page with this address already exists in that section.", table: "StoryBible")
    case .revisionNotFound: String(localized: "That version no longer exists.", table: "StoryBible")
    case .revisionUnreadable: String(localized: "That version is stored in a form this version cannot read.", table: "StoryBible")
    case .invalidKey: String(localized: "The address needs at least one letter or digit.", table: "StoryBible")
    case .blank: String(localized: "A name is required.", table: "StoryBible")
    case .noChanges: String(localized: "Nothing was changed.", table: "StoryBible")
    case .unreadable: String(localized: "This record is stored in a form this version cannot read.", table: "StoryBible")
    case .novelNotFound: String(localized: "This novel could not be found. It may have been removed on another device.", table: "StoryBible")
    default: nil
    }
  }
}
