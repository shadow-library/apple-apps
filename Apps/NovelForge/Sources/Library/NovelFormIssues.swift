import Foundation
import NovelForgeCore
import ShadowAppShell

struct NovelFormIssues: Equatable {
  var title: String?
  var notes: String?
  var form: PresentedError?

  static let none = NovelFormIssues()

  init(title: String? = nil, notes: String? = nil, form: PresentedError? = nil) {
    self.title = title
    self.notes = notes
    self.form = form
  }

  init(_ error: DomainError) {
    switch error {
    case .blank(let field) where Self.isTitle(field):
      self = NovelFormIssues(title: String(localized: "Give the novel a name.", table: "Library"))
    case .tooLong(let field, let limit) where Self.isTitle(field):
      self = NovelFormIssues(title: Self.titleTooLong(limit))
    case .tooLong(let field, _) where field == "notes":
      self = NovelFormIssues(notes: Self.notesOverCharacters)
    case .notesTooLong:
      self = NovelFormIssues(notes: Self.notesOverWords)
    default:
      self = NovelFormIssues(form: PresentedError(error, known: LibraryErrors.headline))
    }
  }

  static var notesOverWords: String {
    String(localized: "That is over the \(LibraryLimits.notesWords, format: .number)-word limit. Trim your notes.", table: "Library")
  }

  static var notesOverCharacters: String {
    String(localized: "Your notes are over \(LibraryLimits.notesCharacters, format: .number) characters. Trim them.", table: "Library")
  }

  static func titleTooLong(_ limit: Int) -> String {
    String(localized: "Keep the title to \(limit, format: .number) characters.", table: "Library")
  }

  private static func isTitle(_ field: String) -> Bool {
    field == "title" || field == "name"
  }
}
