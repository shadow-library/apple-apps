// apps/novel-forge-server/src/database/schemas/finalize-review.ts:33 without `reverted`: phase 7 has no revert of applied updates.
enum FinalizeReviewStatus: String, CaseIterable, Sendable {
  case preparing
  case ready
  case failed
  case applied
}

// apps/novel-forge-server/src/database/schemas/finalize-review.ts:24 without the row id, position and decision time.
struct FinalizeReviewItem: Equatable, Sendable {
  // apps/novel-forge-server/src/modules/ai/isolation-read-policy.ts:41
  static let withheldEvidence = "[excerpt withheld: unrestricted chapter]"

  var itemKey: String
  var category: FinalizeCategory
  var triage: FinalizeTriage
  var basis: FinalizeBasis
  var subjectKey: String
  var claim: String
  var evidence: String?
  var proposed: ProposedChange
  var flag: FinalizeFlag?
  var dependents: [String]?
  var decision: FinalizeDecision?
  var edited: ProposedChange?
  var reason: String?
  var autoKept: Bool
}

/// The author's answer to one item of a revision's review, keyed by (chapter, draft revision, item key) like `nf_finalize_decision`.
struct FinalizeAnswer: Equatable, Sendable {
  var itemKey: String
  var decision: FinalizeDecision
  var proposalDigest: String
  var edited: ProposedChange?
  var reason: String?
  var autoKept: Bool

  init(itemKey: String, decision: FinalizeDecision, proposalDigest: String, edited: ProposedChange? = nil, reason: String? = nil, autoKept: Bool = false) {
    self.itemKey = itemKey
    self.decision = decision
    self.proposalDigest = proposalDigest
    self.edited = edited
    self.reason = reason
    self.autoKept = autoKept
  }

  init(answering item: FinalizeReviewItem, decision: FinalizeDecision, edited: ProposedChange? = nil, reason: String? = nil) {
    self.init(itemKey: item.itemKey, decision: decision, proposalDigest: item.proposed.digest, edited: edited, reason: reason)
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:68
let routineCategories: [FinalizeCategory] = [.appearance, .characterState, .relationship, .promise, .entity, .milestone]

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:71 over the novel's `auto_keep`, nil until the author chooses.
func effectiveAutoKeep(_ chosen: [FinalizeCategory]?) -> [FinalizeCategory] {
  chosen ?? routineCategories
}
