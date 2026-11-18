/// One revision's latest read with the author's answers at that revision.
struct RevisionReview: Sendable {
  var revision: String
  var items: [FinalizeReviewItem]
  var answers: [FinalizeAnswer]
}

private struct Prior {
  var decision: FinalizeDecision
  var proposalDigest: String
  var edited: ProposedChange?
  var reason: String?
  var autoKept: Bool
}

/// apps/novel-forge-server/src/modules/finalize-review/finalize-review.service.ts:523-554 at read time. The reference matches a keep or edit against the item stored
/// on the review row, so a re-read that proposes something else or leaves the item out erases the answer; here the answer names its proposal by digest and stands.
func carryAnswers(onto items: [FinalizeReviewItem], answers: [FinalizeAnswer], earlier: [FinalizeReviewItem]) -> [FinalizeReviewItem] {
  var answered: [JSString: Prior] = [:]
  for item in earlier where item.decision == .skipped && item.category != .summary {
    answered[JSString(item.itemKey)] = Prior(decision: .skipped, proposalDigest: item.proposed.digest, edited: item.edited, reason: item.reason, autoKept: item.autoKept)
  }
  for answer in answers where !answer.autoKept {
    answered[JSString(answer.itemKey)] = Prior(
      decision: answer.decision, proposalDigest: answer.proposalDigest, edited: answer.edited, reason: answer.reason, autoKept: answer.autoKept)
  }
  return items.map { item in
    var carried = item
    guard let prior = answered[JSString(item.itemKey)], prior.decision == .skipped || prior.proposalDigest == item.proposed.digest else {
      carried.edited = nil
      carried.reason = nil
      return carried
    }
    carried.decision = prior.decision
    carried.edited = prior.edited
    carried.reason = prior.reason
    carried.autoKept = prior.autoKept
    return carried
  }
}

/// The latest revision's items as the author's answers leave them, the chain oldest first; skips flow from each revision's resolved items into the next.
/// Pass one entry per revision: its latest read by a deterministic total order over the appended reads, the same read `reviewRefusal` is given.
func resolveReviewChain(_ chain: [RevisionReview]) -> [FinalizeReviewItem] {
  chain.reduce([]) { earlier, review in carryAnswers(onto: review.items, answers: review.answers, earlier: earlier) }
}
