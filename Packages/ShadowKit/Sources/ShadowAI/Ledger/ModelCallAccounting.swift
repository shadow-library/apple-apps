public struct ModelCallAttempt: Sendable, Equatable {
  public let requestID: String?
  public let generationID: String?
  public let outcome: LedgerOutcome
  public let usage: TokenUsage
  public let reportedCost: Cost?

  public init(requestID: String?, generationID: String?, outcome: LedgerOutcome, usage: TokenUsage, reportedCost: Cost?) {
    self.requestID = requestID
    self.generationID = generationID
    self.outcome = outcome
    self.usage = usage
    self.reportedCost = reportedCost
  }
}

public enum ModelCallAccounting {
  private struct Pending {
    var requestID: String?
    var generationID: String?
    var began = false
    var finished: (usage: TokenUsage, reportedCost: Cost?)?
  }

  public static func attempts(from events: [ModelEvent], endedWith error: ModelError?) -> [ModelCallAttempt] {
    var attempts: [ModelCallAttempt] = []
    var current = Pending()
    for event in events {
      switch event {
      case .started(let requestID, let generationID):
        current.requestID = requestID
        current.generationID = generationID
        current.began = true
      case .textDelta:
        current.began = true
      case .retrying(_, _, _, let requestID, let generationID):
        if requestID != nil || generationID != nil {
          attempts.append(ModelCallAttempt(requestID: requestID, generationID: generationID, outcome: .failed, usage: .zero, reportedCost: nil))
        }
        current = Pending()
      case .finished(let usage, let reportedCost, _):
        current.finished = (usage, reportedCost)
        current.began = true
      }
    }
    guard current.began else { return attempts }
    let last = ModelCallAttempt(
      requestID: current.requestID,
      generationID: current.generationID,
      outcome: current.finished != nil ? .finished : error == .cancelled ? .cancelled : .failed,
      usage: current.finished?.usage ?? .zero,
      reportedCost: current.finished?.reportedCost
    )
    var seen = Set<String>()
    let abandoned = attempts.filter { attempt in
      guard let generation = attempt.generationID else { return true }
      return generation != last.generationID && seen.insert(generation).inserted
    }
    return abandoned + [last]
  }

  public static func cost(for attempt: ModelCallAttempt, model: String, catalog: ModelCatalog?) -> (cost: Cost?, source: LedgerCostSource) {
    if let reported = attempt.reportedCost { return (reported, .reported) }
    switch attempt.outcome {
    case .finished:
      guard let computed = catalog?.cost(of: attempt.usage, model: model) else { return (nil, .pending) }
      return (computed, .computed)
    case .failed, .cancelled, .started:
      return attempt.generationID == nil ? (.zero, .computed) : (nil, .pending)
    }
  }
}
