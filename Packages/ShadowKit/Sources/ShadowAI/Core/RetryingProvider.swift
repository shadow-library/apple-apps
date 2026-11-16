/// Retries retryable errors with backoff. A stream is retried only until its first `textDelta` or `finished`; after that an error passes through.
/// Each attempt's ids are reported once: on its `retrying` when it is retried, otherwise on its `started` before the outcome.
public struct RetryingProvider<Base: ModelProvider, C: Clock>: ModelProvider where C.Duration == Duration {
  public let base: Base
  public let policy: RetryPolicy
  private let clock: C
  private let random: @Sendable () -> Double

  public init(_ base: Base, policy: RetryPolicy = .init(), clock: C, random: @escaping @Sendable () -> Double = { .random(in: 0..<1) }) {
    self.base = base
    self.policy = policy
    self.clock = clock
    self.random = random
  }

  public func stream(_ request: ModelRequest) -> ModelStream {
    ModelStream { continuation throws(ModelError) in
      var attempt = 1
      while true {
        var started: (requestID: String?, generationID: String?)?
        var committed = false
        do throws(ModelError) {
          for try await event in base.stream(request) {
            switch event {
            case .started(let requestID, let generationID) where !committed:
              started = (requestID, generationID)
            case .textDelta, .finished:
              if !committed { try Self.release(started, to: continuation) }
              committed = true
              try continuation.yield(event)
            case .started, .retrying:
              try continuation.yield(event)
            }
          }
          if !committed { try Self.release(started, to: continuation) }
          return
        } catch {
          guard !committed else { throw error }
          let delay: Duration
          do throws(ModelError) {
            delay = try retryDelay(after: error, attempt: attempt)
          } catch {
            try? Self.release(started, to: continuation)
            throw error
          }
          try continuation.yield(.retrying(attempt: attempt, delay: delay, cause: error, requestID: started?.requestID, generationID: started?.generationID))
          try await pause(for: delay)
          attempt += 1
        }
      }
    }
  }

  public func validate(_ credential: ProviderCredential) async throws(ModelError) -> CredentialStatus {
    try await retrying { () async throws(ModelError) in try await base.validate(credential) }
  }

  public func models() async throws(ModelError) -> [RemoteModel] {
    try await retrying { () async throws(ModelError) in try await base.models() }
  }

  private func retrying<Value>(_ operation: () async throws(ModelError) -> Value) async throws(ModelError) -> Value {
    var attempt = 1
    while true {
      do throws(ModelError) {
        return try await operation()
      } catch {
        try await pause(for: try retryDelay(after: error, attempt: attempt))
        attempt += 1
      }
    }
  }

  private static func release(_ started: (requestID: String?, generationID: String?)?, to continuation: ModelStream.Continuation) throws(ModelError) {
    guard let started else { return }
    try continuation.yield(.started(requestID: started.requestID, generationID: started.generationID))
  }

  private func retryDelay(after error: ModelError, attempt: Int) throws(ModelError) -> Duration {
    guard error.isRetryable, attempt < policy.maxAttempts else { throw error }
    guard !Task.isCancelled else { throw .cancelled }
    return policy.delay(forAttempt: attempt, retryAfter: error.retryAfter, random: random())
  }

  private func pause(for delay: Duration) async throws(ModelError) {
    do {
      try await clock.sleep(for: delay)
    } catch {
      throw .cancelled
    }
  }
}

extension RetryingProvider where C == ContinuousClock {
  public init(_ base: Base, policy: RetryPolicy = .init()) {
    self.init(base, policy: policy, clock: ContinuousClock())
  }
}
