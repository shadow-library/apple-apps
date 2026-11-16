import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/classes/app-error-code.ts:220
public enum NotebookError: ShadowError {
  case novelNotFound(UUID)
  case entryNotFound(UUID)
  case entryNotActive(UUID)
  case entryNotUnderstood(UUID)
  case onlyDecisionOrSystemDetailBecomesDecision
  case malformedTopic(String)
  case reservedTopic(String)
  case kindNotAllowed(String)
  case blank(field: String)
  case tooLong(field: String, limit: Int)
  case tooMany(field: String, limit: Int)
  case invalidRejection(String)
  case ideaAlreadyRejected(String)
  case store(StoreError)

  public var code: String {
    switch self {
    case .novelNotFound: "PRJ_001"
    case .entryNotFound: "LDG_001"
    case .entryNotActive: "LDG_002"
    case .entryNotUnderstood: "notebook.entry_not_understood"
    case .onlyDecisionOrSystemDetailBecomesDecision: "LDG_003"
    case .malformedTopic: "LDG_004"
    case .reservedTopic: "LDG_005"
    case .kindNotAllowed: "notebook.kind_not_allowed"
    case .blank: "notebook.blank"
    case .tooLong: "notebook.too_long"
    case .tooMany: "notebook.too_many"
    case .invalidRejection: "notebook.invalid_rejection"
    case .ideaAlreadyRejected: "notebook.idea_already_rejected"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .novelNotFound: "Project not found"
    case .entryNotFound: "Ledger entry not found"
    case .entryNotActive: "Ledger entry is already superseded or withdrawn — change the active entry on its topic instead"
    case .entryNotUnderstood: "The entry was written by a newer version of the app and cannot be rewritten here"
    case .onlyDecisionOrSystemDetailBecomesDecision: "Only a decision or a system detail can be rewritten as a decision"
    case .malformedTopic(let topic): "Ledger topic \"\(topic)\" is not a key of lowercase words joined by dots, dashes or underscores"
    case .reservedTopic(let topic): "Topic \"\(topic)\" is reserved for the server; the author cannot write to it directly"
    case .kindNotAllowed(let kind): "The author cannot write an entry of kind \"\(kind)\""
    case .blank(let field): "\(field) must not be blank"
    case .tooLong(let field, let limit): "\(field) must be at most \(limit) characters"
    case .tooMany(let field, let limit): "\(field) must have at most \(limit) items"
    case .invalidRejection(let reason): "A rejected idea needs a rejected entry, a scope, and an anchor exactly when the scope is not never: \(reason)"
    case .ideaAlreadyRejected(let idea): "Idea \(idea) already has an active rejection"
    case .store(let error): error.errorDescription
    }
  }
}
