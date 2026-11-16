public enum StopReason: Sendable, Equatable {
  case endTurn
  case maxTokens
  case refusal(category: String?)
  case contentFilter
  case other(String)
}

/// A well-formed stream is zero or more `retrying`, then an optional `started`, then zero or more `textDelta` and one `finished`, or an error at any point;
/// every attempt that produced ids reports them once, on its `started` or its `retrying`.
public enum ModelEvent: Sendable, Equatable {
  case started(requestID: String?, generationID: String?)
  case textDelta(String)
  /// `attempt` is the failed attempt, starting at 1; the ids are from its `started`, nil if it never started, so a billed attempt can be reconciled.
  case retrying(attempt: Int, delay: Duration, cause: ModelError, requestID: String?, generationID: String?)
  case finished(usage: TokenUsage, reportedCost: Cost?, stop: StopReason)
}

public struct ModelResponse: Sendable, Equatable {
  public let text: String
  public let usage: TokenUsage
  public let reportedCost: Cost?
  public let stop: StopReason
  public let requestID: String?
  public let generationID: String?

  public init(text: String, usage: TokenUsage, reportedCost: Cost?, stop: StopReason, requestID: String?, generationID: String?) {
    self.text = text
    self.usage = usage
    self.reportedCost = reportedCost
    self.stop = stop
    self.requestID = requestID
    self.generationID = generationID
  }
}
