public struct RetryPolicy: Sendable, Equatable {
  public static let retryAfterCap = Duration.seconds(600)

  public var maxAttempts: Int
  public var baseDelay: Duration
  public var maxDelay: Duration
  public var jitter: Double

  public init(maxAttempts: Int = 5, baseDelay: Duration = .seconds(1), maxDelay: Duration = .seconds(60), jitter: Double = 0.2) {
    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitter = jitter
  }

  /// `attempt` is the failed attempt, starting at 1. Jitter only shortens the backoff, by `jitter × random` of it, to whole milliseconds.
  public func delay(forAttempt attempt: Int, retryAfter: Duration?, random: Double) -> Duration {
    let ceiling = max(maxDelay, .zero)
    var backoff = min(max(baseDelay, .zero), ceiling)
    var doublings = max(attempt, 1) - 1
    while doublings > 0, backoff < ceiling {
      backoff = min(backoff * 2, ceiling)
      doublings -= 1
    }
    let spread = min(max(jitter, 0), 1) * min(max(random, 0), 1)
    let jittered = Duration.milliseconds((backoff / .milliseconds(1) * (1 - spread)).rounded())
    guard let retryAfter else { return jittered }
    return max(jittered, min(max(retryAfter, .zero), Self.retryAfterCap))
  }
}
