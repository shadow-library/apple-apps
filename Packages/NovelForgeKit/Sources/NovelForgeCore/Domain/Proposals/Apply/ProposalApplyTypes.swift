import Foundation
import ShadowCore
import ShadowStore

/// Whether this build can write unrestricted text: store builds ship without it until App Review accepts it, so no apply raises a plan to unrestricted.
enum UnrestrictedWriting {
  static let isAvailable = false
}

// apps/novel-forge-server/src/modules/refinement/proposal-apply.service.ts:36-44
struct ProposalApplyContext: Sendable {
  let novel: UUID
  var now: Date
  /// Set when a turn applies what the write policy let through; such an apply carries no action and no always-card op.
  var automatic = false
  /// The write policy's source for each op of the change set, indexed like it; kept only in the first applier's `applied` object.
  var sources: [OpSource]?
  /// apply/unrestricted-raise.ts:18: whether unrestricted writing is available to this caller, asked only when a selected op raises a plan to it.
  var unrestrictedAvailable = UnrestrictedWriting.isAvailable

  init(novel: UUID, now: Date, automatic: Bool = false, sources: [OpSource]? = nil, unrestrictedAvailable: Bool = UnrestrictedWriting.isAvailable) {
    self.novel = novel
    self.now = now
    self.automatic = automatic
    self.sources = sources
    self.unrestrictedAvailable = unrestrictedAvailable
  }
}

/// Why a selected index did not apply, as stored on its change: the message in `error`, the code in `result.code`.
struct ProposalChangeFailure: Sendable, Equatable {
  let code: String
  let message: String

  init(code: String, message: String) {
    self.code = code
    self.message = message
  }

  init(_ error: ApplyError) {
    self.init(code: error.code, message: error.errorDescription ?? error.code)
  }

  // proposal-apply.service.ts:265
  static let previousActionFailed = ProposalChangeFailure(code: "refinement.action_skipped", message: "skipped — a previous action failed")

  var stored: ProposalChangeResult {
    ProposalChangeResult(error: message, result: ["code": .string(code)])
  }
}

/// What one selected index amounted to (apply.types.ts:15); an action is `pending` until it runs after the content commits.
struct ProposalChangeOutcome: Sendable, Equatable {
  let index: Int
  var status: ProposalChangeStatus
  let source: OpSource?
  var failure: ProposalChangeFailure?
  /// What a settled action reported (action-registry.ts:6).
  var summary: String?
}

enum ProposalApplyOutcome: Sendable, Equatable {
  /// proposal-apply.service.ts:148-160 (RFN_003): nothing was applied and no change was recorded; `conflicted` is derived, never stored.
  case conflicted([BaselineMismatch])
  /// One outcome per selected index, in index order.
  case applied([ProposalChangeOutcome])
}

enum ProposalApplyError: ShadowError, Equatable {
  case notFound(UUID)
  case notPending(StoredEnum<ProposalDecision>)
  case unreadable(UUID)
  case oneWayDoor(OpType)
  case automaticAction
  case automaticAlwaysCard(OpType)
  case sourcesMismatch(expected: Int, found: Int)
  case planCardStale(chapter: Int, next: Int)
  case apply(ApplyError)
  /// A handler refused the call that applies these indexes, so nothing was applied and the card stays pending; the message is the refusal's own.
  case changeRefused(indexes: [Int], ApplyError)
  /// An action threw: the action's transaction is abandoned and its change settled as failed in a write of its own.
  case action(index: Int, ApplyError)
  case domain(DomainError)
  case unstorable(ProposalRecordError)
  case store(StoreError)

  var code: String {
    switch self {
    case .notFound: "RFN_001"
    case .notPending: "RFN_002"
    case .unreadable: "refinement.unreadable_record"
    // proposal-apply.service.ts:65-71
    case .oneWayDoor(let type):
      switch type {
      case .actionFinalize: "RFN_009"
      case .actionApproveDraft: "DRF_009"
      case .actionApplyContinuity: "CNT_002"
      case .actionGenerateChapter: "DRF_014"
      default: "VOL_004"
      }
    case .automaticAction: "refinement.automatic_action"
    case .automaticAlwaysCard: "refinement.automatic_always_card"
    case .sourcesMismatch: "refinement.sources_mismatch"
    case .planCardStale: "PLN_008"
    case .apply(let error), .changeRefused(_, let error), .action(_, let error): error.code
    case .domain(let error): error.code
    case .unstorable(let error): error.code
    case .store(let error): error.code
    }
  }

  var errorDescription: String? {
    switch self {
    case .notFound: "Refinement proposal not found"
    case .notPending: "Refinement proposal is not pending"
    case .unreadable: "This proposal cannot be read on this device, so it is not applied"
    case .oneWayDoor(let type):
      switch type {
      case .actionFinalize: "Finalize is never applied automatically — select the finalize step and apply it deliberately"
      case .actionApproveDraft: "Draft approval is never applied automatically — select the approval step and apply it deliberately"
      case .actionApplyContinuity: "Adding a chapter to the Story Bible is never applied automatically — select the action and apply it deliberately"
      case .actionGenerateChapter: "Chapter generation is never applied automatically — select the generation step and apply it deliberately"
      default: "Goal met — start next is never applied automatically — select the action and apply it deliberately"
      }
    case .automaticAction: "an automatic apply carries content ops only — actions are always the author’s selection"
    case .automaticAlwaysCard(let type): "an automatic apply never carries \(type.rawValue) — the write policy keeps it a card for the author"
    case .sourcesMismatch(let expected, let found): "an automatic apply carries one source per op of its change-set (\(expected), not \(found))"
    case .planCardStale(let chapter, let next): "The plan for chapter \(chapter) is out of date — the story has moved on to chapter \(next); plan again"
    case .apply(let error), .changeRefused(_, let error), .action(_, let error): error.errorDescription
    case .domain(let error): error.errorDescription
    case .unstorable(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }

  static func == (left: ProposalApplyError, right: ProposalApplyError) -> Bool {
    switch (left, right) {
    case (.notFound(let first), .notFound(let second)), (.unreadable(let first), .unreadable(let second)): first == second
    case (.notPending(let first), .notPending(let second)): first == second
    case (.oneWayDoor(let first), .oneWayDoor(let second)), (.automaticAlwaysCard(let first), .automaticAlwaysCard(let second)): first == second
    case (.automaticAction, .automaticAction): true
    case (.sourcesMismatch(let first, let found), .sourcesMismatch(let second, let other)): first == second && found == other
    case (.planCardStale(let first, let next), .planCardStale(let second, let other)): first == second && next == other
    case (.apply(let first), .apply(let second)): first == second
    case (.changeRefused(let first, let cause), .changeRefused(let second, let other)): first == second && cause == other
    case (.action(let first, let cause), .action(let second, let other)): first == second && cause == other
    case (.domain(let first), .domain(let second)): first == second
    case (.unstorable(let first), .unstorable(let second)): first == second
    case (.store(let first), .store(let second)): first.code == second.code && first.errorDescription == second.errorDescription
    default: false
    }
  }
}
