import ShadowText

private let intentTurns = 3
private let minIntentWords = 2
private let bareEdges = ProseRegex.literal(#"^["'\s]+|["'\s.!…]+$"#, "gu")

struct PlanSteer: Equatable, Sendable {
  var intent: String?
  var direction: String?
  var droppedIntent: String?
}

struct PlanCardOrigin: Equatable, Sendable {
  var sessionId: String?
  var messageId: Int?
  var proposalId: Int
}

struct PlanChatMessage: Equatable, Sendable {
  var id: Int
  var sessionId: String
  var isAuthor: Bool
  var content: String
  var contexts: [ChatPassageContext]?
}

struct PriorProposal: Equatable, Sendable {
  var id: Int
  var sessionId: String
  var messageId: Int?
  var plansChapter: Bool
}

private func steerText(_ text: String?) -> String? {
  guard let trimmed = text?.jsTrim(), !trimmed.isEmpty else { return nil }
  return trimmed
}

extension QuoteRule {
  // apps/novel-forge-server/src/modules/actions/plan-job.service.ts:74
  fileprivate func bare(_ text: String) -> String {
    normaliseForQuote(text).jsReplace(bareEdges, "")
  }

  // apps/novel-forge-server/src/modules/actions/plan-job.service.ts:79
  func intentStatedIn(_ intent: String, message: String) -> Bool {
    let needle = bare(intent)
    if needle.isEmpty { return false }
    let whole = splitSentences(message).contains { bare($0).jsEquals(needle) }
    let contained = contentTokens(needle).count >= minIntentWords && normaliseForQuote(message).jsIncludes(needle)
    return (whole || contained) && !quoteIsTentative(needle, message)
  }

  // apps/novel-forge-server/src/modules/actions/plan-job.service.ts:96
  func planSteer(intent: String?, direction: String?, authorMessages: [String]) -> PlanSteer {
    let said = steerText(intent)
    let chosen = steerText(direction)
    if let said, authorMessages.contains(where: { intentStatedIn(said, message: $0) }) { return PlanSteer(intent: said, direction: chosen) }
    if let said, let chosen { return PlanSteer(direction: chosen, droppedIntent: said) }
    return PlanSteer(direction: chosen ?? said)
  }
}

// apps/novel-forge-server/src/modules/actions/plan-job.service.ts:43
// Int ids must be an ordinal following append order, consistent across replicas.
func authorMessagesFor(_ origin: PlanCardOrigin, messages: [PlanChatMessage], proposals: [PriorProposal]) -> [String] {
  guard let sessionId = origin.sessionId, !sessionId.isEmpty, let messageId = origin.messageId else { return [] }
  guard let answered = messages.first(where: { $0.id == messageId }) else { return [] }
  let previousPlan = proposals.filter { $0.sessionId == answered.sessionId && $0.id < origin.proposalId && $0.plansChapter }.max { $0.id < $1.id }
  let floor = previousPlan?.messageId
  func isAfterFloor(_ id: Int) -> Bool { floor.map { id > $0 } ?? true }
  return
    messages
    .filter { $0.sessionId == answered.sessionId && $0.isAuthor && $0.id <= messageId && isAfterFloor($0.id) }
    .sorted { $0.id > $1.id }
    .prefix(intentTurns)
    .map { authorWords($0.content, contexts: $0.contexts) }
}
