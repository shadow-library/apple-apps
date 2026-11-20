import ShadowCore
import ShadowText

/// The milestones a final chapter reached. Without a review it reaches what its contract claims
/// (apps/novel-forge-server/src/modules/ai/graphs/chapter-finalization.graph.ts:177); with one, only what the author kept: a claim the review left unreached
/// is dropped (apps/novel-forge-server/src/modules/finalize-review/finalize-review-gate.ts:161-166) and a kept milestone reached, claimed or not
/// (apps/novel-forge-server/src/modules/finalize-review/review-event-apply.ts:216-222). A review this version cannot read reaches nothing.
enum CanonMilestones {
  /// From the stored canon's `review` member, for a reader that does not decode the whole canon.
  static func reached(claims: [String], review stored: JSONValue?) -> [String] {
    guard let stored, !stored.isNull else { return claims }
    guard let review = CanonReview(json: stored) else { return [] }
    return reached(claims: claims, review)
  }

  static func reached(_ canon: Canon) -> [String] {
    guard canon.unrecognised[FinalChapterCanonMember.review.rawValue] == nil else { return [] }
    guard let review = canon.review else { return canon.contract.claimedMilestones }
    return reached(claims: canon.contract.claimedMilestones, review)
  }

  private static func reached(claims: [String], _ review: CanonReview) -> [String] {
    let unreached = Set(review.unreached.map { JSString($0.jsNormalize(.nfc)) })
    let kept = review.kept.compactMap { item -> String? in
      guard case .milestone(let milestone)? = ProposedChange(json: .object(item)), milestone.reached else { return nil }
      return milestone.milestoneKey
    }
    return claims.filter { !unreached.contains(JSString($0.jsNormalize(.nfc))) } + kept
  }
}
