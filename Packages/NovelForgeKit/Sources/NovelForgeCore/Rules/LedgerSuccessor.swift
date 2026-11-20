import Foundation
import ShadowCore
import ShadowText

enum LedgerRuleError: ShadowError, Equatable {
  case onlyDecisionOrSystemDetailBecomesDecision

  var code: String { "LDG_003" }

  var errorDescription: String? {
    switch self {
    case .onlyDecisionOrSystemDetailBecomesDecision: "Only a decision or a system detail can be rewritten as a decision"
    }
  }
}

public enum LedgerEntryStatus: String, CaseIterable, Codable, Sendable {
  case active
  case superseded
  case withdrawn
}

enum AuthorSupersedeKind: String, CaseIterable, Codable, Sendable {
  case decision
  case direction
  case rejected
  case backlog

  var entryKind: LedgerEntryKind {
    switch self {
    case .decision: .decision
    case .direction: .direction
    case .rejected: .rejected
    case .backlog: .backlog
    }
  }
}

struct LedgerIdeaRejection: Equatable, Sendable {
  var ideaId: String
  var scope: LedgerRejectionScope
  var anchor: JSONValue?
}

struct SupersededLedgerEntry: Equatable, Sendable {
  var kind: LedgerEntryKind
  var why: String?
  var writerLine: String?
  var rejectedAlternatives: [String]
  var payload: JSONValue?
  var links: JSONValue
  var stepKey: String?
  var ideaId: String?
  var rejectionScope: LedgerRejectionScope?
  var rejectionAnchor: JSONValue?
}

struct AuthorSupersession: Equatable, Sendable {
  var kind: AuthorSupersedeKind?
  var statement: String
  var why: String?
  var writerLine: String?
  var rejectedAlternatives: [String]?
  var payload: JSONValue?
}

struct SupersedingEntry: Equatable, Sendable {
  var kind: LedgerEntryKind
  var decidedBy: LedgerDecidedBy
  var statement: String
  var why: String?
  var writerLine: String?
  var rejectedAlternatives: [String]
  var payload: JSONValue?
  var links: JSONValue
  var stepKey: String?
  var idea: LedgerIdeaRejection?
}

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts:22
private func clearable(_ value: String?, inherited: String?) -> String? {
  guard let value else { return inherited }
  let trimmed = value.jsTrim()
  return trimmed.isEmpty ? nil : trimmed
}

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts:47
private func inheritedIdea(_ previous: SupersededLedgerEntry) -> LedgerIdeaRejection? {
  guard let ideaId = previous.ideaId, let scope = previous.rejectionScope else { return nil }
  return LedgerIdeaRejection(ideaId: ideaId, scope: scope, anchor: previous.rejectionAnchor)
}

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts:53
func authorSuccessor(_ previous: SupersededLedgerEntry, _ input: AuthorSupersession) throws(LedgerRuleError) -> SupersedingEntry {
  let kind = input.kind?.entryKind ?? (previous.kind == .system ? .decision : previous.kind)
  if kind == .decision, previous.kind != .decision, previous.kind != .system { throw .onlyDecisionOrSystemDetailBecomesDecision }

  let inherits = kind == previous.kind || (kind == .decision && previous.kind == .system)
  let payload = input.payload?.isNull == true ? nil : input.payload
  return SupersedingEntry(
    kind: kind,
    decidedBy: .author,
    statement: input.statement,
    why: clearable(input.why, inherited: inherits ? previous.why : nil),
    writerLine: clearable(input.writerLine, inherited: inherits ? previous.writerLine : nil),
    rejectedAlternatives: input.rejectedAlternatives ?? (inherits ? previous.rejectedAlternatives : []),
    payload: payload ?? (inherits ? previous.payload : nil),
    links: inherits ? previous.links : .object([:]),
    stepKey: inherits ? previous.stepKey : nil,
    idea: inherits && kind == .rejected ? inheritedIdea(previous) : nil
  )
}

// apps/novel-forge-server/src/modules/ledger/ledger.service.ts:72
func ledgerEntryStatus(supersededAt: Date?, withdrawnReason: String?) -> LedgerEntryStatus {
  guard supersededAt != nil else { return .active }
  return withdrawnReason == nil ? .superseded : .withdrawn
}
