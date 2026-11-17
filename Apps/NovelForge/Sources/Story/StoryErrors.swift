import Foundation
import NovelForgeCore

enum StoryErrors {
  static func headline(for error: DomainError) -> String? {
    switch error {
    case .volumeNotFound: String(localized: "This volume could not be found. It may have been removed on another device.", table: "Story")
    case .volumeExists: String(localized: "A volume with this key already exists.", table: "Story")
    case .volumeNotActive: String(localized: "Only the active volume's goal can be marked met.", table: "Story")
    case .volumeInPlan(_, let chapter): String(localized: "This volume is still used by the plan for chapter \(chapter). Move or remove that plan first.", table: "Story")
    case .milestoneNotFound: String(localized: "This milestone could not be found. It may have been removed on another device.", table: "Story")
    case .milestoneExists: String(localized: "A milestone with this key already exists.", table: "Story")
    case .milestoneReferenced: String(localized: "A chapter plan or a secret's unlock condition still uses this milestone. Remove those references first.", table: "Story")
    case .milestoneSubjectUnknown: String(localized: "The subject must be a character, place or other entity from your story bible.", table: "Story")
    case .promiseNotFound: String(localized: "This promise could not be found. It may have been removed on another device.", table: "Story")
    case .promiseExists: String(localized: "A promise with this key already exists.", table: "Story")
    case .secretNotFound: String(localized: "This secret could not be found. It may have been removed on another device.", table: "Story")
    case .entityUnknown: String(localized: "That character is not in your story bible any more.", table: "Story")
    case .unlockMalformed: String(localized: "The unlock condition is not valid. Check each term.", table: "Story")
    case .invalidKey: String(localized: "The key must not be empty or contain spaces.", table: "Story")
    case .blank: String(localized: "A required field is blank.", table: "Story")
    case .tooLong: String(localized: "A field is over its length limit. Shorten it.", table: "Story")
    case .belowMinimum: String(localized: "Chapter numbers start at 1.", table: "Story")
    case .noChanges: String(localized: "Nothing was changed.", table: "Story")
    default: nil
    }
  }
}
