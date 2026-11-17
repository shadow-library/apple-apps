import Foundation
import ShadowCore
import ShadowStore

// apps/novel-forge-server/src/classes/app-error-code.ts:166-169
enum ProposalStagingError: ShadowError, Equatable {
  case notAllowed(problems: [String])
  case rewriteNotPlaced(chapter: Int, reason: RewriteDropReason)
  case ideaIdsUnavailable
  case approvalOverMovedDraft(chapter: Int)
  case unstorable(ProposalRecordError)
  case draft(ApplyError)
  case domain(DomainError)
  case store(StoreError)

  var code: String {
    switch self {
    case .notAllowed, .rewriteNotPlaced: "RFN_004"
    case .ideaIdsUnavailable: "refinement.idea_ids_unavailable"
    case .approvalOverMovedDraft: "refinement.approval_over_moved_draft"
    case .unstorable(let error): error.code
    case .draft(let error): error.code
    case .domain(let error): error.code
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .notAllowed(let problems): "Change-set operation not allowed for this scope: \(problems.joined(separator: "; "))"
    case .rewriteNotPlaced(let chapter, let reason): "Change-set operation not allowed for this scope: the rewrite in chapter \(chapter) cannot be placed — \(reason.why)"
    case .ideaIdsUnavailable: "This device cannot tell the ideas of the change apart, so it is not staged"
    case .approvalOverMovedDraft(let chapter):
      "Chapter \(chapter) has unsaved edits over an earlier version of its draft — save or close the chapter, then ask for the approval again"
    case .unstorable(let error): error.errorDescription
    case .draft(let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  static func == (left: ProposalStagingError, right: ProposalStagingError) -> Bool {
    left.code == right.code && left.errorDescription == right.errorDescription
  }
}

// app-error-code.ts:166-167
public enum ProposalDecisionError: ShadowError, Equatable {
  case notFound(UUID)
  case notPending(StoredEnum<ProposalDecision>?)
  case store(StoreError)

  public var code: String {
    switch self {
    case .notFound: "RFN_001"
    case .notPending: "RFN_002"
    case .store(let error): error.code
    }
  }

  public var errorDescription: String? {
    switch self {
    case .notFound: "Refinement proposal not found"
    case .notPending: "Refinement proposal is not pending"
    case .store(let error): error.errorDescription
    }
  }

  public static func == (left: ProposalDecisionError, right: ProposalDecisionError) -> Bool {
    switch (left, right) {
    case (.notFound(let first), .notFound(let second)): first == second
    case (.notPending(let first), .notPending(let second)): first == second
    case (.store(let first), .store(let second)): first.code == second.code && first.errorDescription == second.errorDescription
    default: false
    }
  }
}
