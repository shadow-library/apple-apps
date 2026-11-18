import ShadowCore

// apps/novel-forge-server/src/classes/app-error-code.ts:296-309
enum FinalizeReviewError: ShadowError, Equatable {
  case preparing
  case readingFailed
  case proseChanged
  case unanswered(count: Int)
  case strandedReveal(StrandedReveal)
  case editRefused(FinalizeEditRefusal)

  var code: String {
    switch self {
    case .preparing: "FRV_002"
    case .readingFailed: "FRV_003"
    case .proseChanged: "FRV_004"
    case .unanswered: "FRV_005"
    case .strandedReveal: "FRV_006"
    case .editRefused: "FRV_009"
    }
  }

  var errorDescription: String? {
    switch self {
    case .preparing: "The Story Bible updates are still being read from the approved revision — try again in a moment"
    case .readingFailed: "Reading the Story Bible updates from this chapter failed — prepare the review again"
    case .proseChanged: "The prose changed since it was approved, so its finalize review no longer applies — approve it again"
    case .unanswered(let count): "Review the Story Bible updates first: \(count) still need an answer"
    case .strandedReveal(let stranded):
      "This chapter reveals \(stranded.facts.joined(separator: ", ")), which needs milestone \(stranded.milestone) — keep the milestone as reached, or revise the plan or the prose"
    case .editRefused(let refusal): "An edited update must keep its kind and the record it is about — \(refusal.reason)"
    }
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:13
struct ReviewedRevision: Sendable {
  var revision: String
  var body: String
}

/// One read of a revision as the commit sees it; a requested read that is not ready yet is `preparing`, one whose job failed is `failed`.
struct FinalizeReviewSnapshot: Sendable {
  var draftRevision: String
  var sourceHash: String
  var status: FinalizeReviewStatus
  var items: [FinalizeReviewItem]
}

struct StrandedReveal: Equatable, Sendable {
  var milestone: String
  var facts: [String]
}

// apps/novel-forge-server/src/modules/review/review-findings.ts:75
func reviewedBodyHash(_ body: String) -> String {
  sha256Hex(body)
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:25
func isReviewCurrent(_ review: FinalizeReviewSnapshot, _ draft: ReviewedRevision) -> Bool {
  review.draftRevision.jsEquals(draft.revision) && review.sourceHash == reviewedBodyHash(draft.body)
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:32
func unreachedClaims(_ items: [FinalizeReviewItem]) -> [FinalizeReviewItem] {
  items.filter { item in
    guard item.category == .milestone, item.flag != .unclaimedMilestone else { return false }
    if item.decision == .skipped { return true }
    guard case .milestone(let milestone) = effectiveChange(item) else { return false }
    return !milestone.reached
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:41
func strandedReveals(_ items: [FinalizeReviewItem]) -> StrandedReveal? {
  guard let stranded = unreachedClaims(items).first(where: { !($0.dependents ?? []).isEmpty }) else { return nil }
  return StrandedReveal(milestone: stranded.subjectKey, facts: stranded.dependents ?? [])
}

/// Decision 2: a finalize review is mandatory, so a revision with no read refuses as still preparing where the reference finalizes on the direct path (no
/// reviews) or asks for a new approval (only other revisions' reviews). Pass one snapshot per revision, the read `resolveReviewChain` treats as latest; the
/// commit checks that the draft head is the approval's revision before asking, since a missing review here never reads as moved prose.
// apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:47
func reviewRefusal(_ reviews: [FinalizeReviewSnapshot], _ draft: ReviewedRevision) -> FinalizeReviewError? {
  guard let review = reviews.first(where: { $0.draftRevision.jsEquals(draft.revision) }) else { return .preparing }
  if !isReviewCurrent(review, draft) { return .proseChanged }
  switch review.status {
  case .applied: return nil
  case .preparing: return .preparing
  case .failed: return .readingFailed
  case .ready: break
  }
  let open = openItems(review.items).count
  if open > 0 { return .unanswered(count: open) }
  return strandedReveals(review.items).map(FinalizeReviewError.strandedReveal)
}
