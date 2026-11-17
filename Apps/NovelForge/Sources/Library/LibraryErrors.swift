import Foundation
import NovelForgeCore

enum LibraryErrors {
  static func headline(for error: DomainError) -> String? {
    switch error {
    case .novelNotFound: String(localized: "This novel could not be found. It may have been removed on another device.", table: "Library")
    case .novelExists: String(localized: "A novel with this identifier already exists.", table: "Library")
    case .wordTargetInverted: String(localized: "The maximum word target must be greater than the minimum.", table: "Library")
    case .noChanges: String(localized: "Nothing was changed.", table: "Library")
    case .unreadableRecords: String(localized: "Some of this novel's records are stored in a form this version cannot read, so it cannot be copied faithfully.", table: "Library")
    case .unreadable: String(localized: "This novel is stored in a form this version cannot read.", table: "Library")
    case .notesTooLong: String(localized: "Your notes are over the word limit. Trim them.", table: "Library")
    default: nil
    }
  }
}
