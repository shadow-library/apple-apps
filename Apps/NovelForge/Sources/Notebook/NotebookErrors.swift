import Foundation
import NovelForgeCore
import ShadowAppShell

enum NotebookErrors {
  static func present(_ error: any Error) -> PresentedError {
    guard let notebook = error as? NotebookError else { return PresentedError(error, known: LibraryErrors.headline) }
    if case .store(let store) = notebook { return PresentedError(store) }
    return PresentedError(headline: headline(for: notebook), detail: notebook.code)
  }

  static func headline(for error: NotebookError) -> String {
    switch error {
    case .novelNotFound: String(localized: "This novel could not be found. It may have been removed on another device.", table: "Notebook")
    case .entryNotFound: String(localized: "This entry could not be found. It may not have reached this device yet.", table: "Notebook")
    case .entryNotActive: String(localized: "This entry has already been replaced or withdrawn. Work on the current entry instead.", table: "Notebook")
    case .entryNotUnderstood: String(localized: "This entry was written by a newer version of Novel Forge and cannot be rewritten here.", table: "Notebook")
    case .onlyDecisionOrSystemDetailBecomesDecision: String(localized: "Only a decision can be rewritten as a decision.", table: "Notebook")
    case .malformedTopic: String(localized: "A topic uses lowercase letters, digits, dots, dashes and underscores, and starts with a letter or digit.", table: "Notebook")
    case .reservedTopic: String(localized: "That topic is reserved for Novel Forge. Choose another.", table: "Notebook")
    case .kindNotAllowed: String(localized: "You cannot write that kind of entry yourself.", table: "Notebook")
    case .blank(let field): blankHeadline(field)
    case .tooLong(_, let limit): String(localized: "That is too long. Keep it to \(limit) characters.", table: "Notebook")
    case .tooMany(_, let limit): String(localized: "There are too many items. Keep it to \(limit).", table: "Notebook")
    case .invalidRejection: String(localized: "This turned-down idea is incomplete.", table: "Notebook")
    case .ideaAlreadyRejected: String(localized: "That idea is already turned down.", table: "Notebook")
    case .store: String(localized: "Your data could not be read or saved.", table: "Navigation")
    }
  }

  private static func blankHeadline(_ field: String) -> String {
    switch field {
    case "statement": String(localized: "Write what this entry says.", table: "Notebook")
    case "reason": String(localized: "Say why you are withdrawing it.", table: "Notebook")
    default: String(localized: "A required field is empty.", table: "Notebook")
    }
  }
}

struct NotebookFormIssues: Equatable {
  var topic: String?
  var statement: String?
  var reason: String?
  var form: PresentedError?

  static let none = NotebookFormIssues()

  init(topic: String? = nil, statement: String? = nil, reason: String? = nil, form: PresentedError? = nil) {
    self.topic = topic
    self.statement = statement
    self.reason = reason
    self.form = form
  }

  init(_ error: any Error) {
    let presented = NotebookErrors.present(error)
    guard let notebook = error as? NotebookError else {
      self.init(form: presented)
      return
    }
    switch notebook {
    case .malformedTopic, .reservedTopic: self.init(topic: presented.headline)
    case .blank(field: "statement"), .tooLong(field: "statement", limit: _): self.init(statement: presented.headline)
    case .blank(field: "reason"), .tooLong(field: "reason", limit: _): self.init(reason: presented.headline)
    default: self.init(form: presented)
    }
  }
}
