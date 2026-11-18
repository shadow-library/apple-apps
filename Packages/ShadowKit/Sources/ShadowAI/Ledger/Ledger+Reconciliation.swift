import Foundation
import ShadowStore

public struct ReconciliationPolicy: Sendable {
  public var maxEntries: Int
  public var maxConcurrent: Int
  public var maxAttempts: Int
  public var backoff: Duration
  public var maxBackoff: Duration
  public var startedGrace: Duration

  public init(
    maxEntries: Int = 50, maxConcurrent: Int = 4, maxAttempts: Int = 4, backoff: Duration = .seconds(2), maxBackoff: Duration = .seconds(30), startedGrace: Duration = .seconds(600)
  ) {
    self.maxEntries = maxEntries
    self.maxConcurrent = maxConcurrent
    self.maxAttempts = maxAttempts
    self.backoff = backoff
    self.maxBackoff = maxBackoff
    self.startedGrace = startedGrace
  }
}

public struct ReconciliationReport: Sendable, Equatable {
  public var reconciled: [UUID] = []
  public var stillPending: [UUID: OpenRouterGenerationError] = [:]
  public var deferred = 0
  public var stoppedByAuthentication = false
}

extension Ledger {
  public static func reconcilePending(
    in store: VaultStore,
    using lookup: OpenRouterGenerationLookup,
    policy: ReconciliationPolicy = .init(),
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async throws(StoreError) -> ReconciliationReport {
    guard let provider = lookup.provider else { return ReconciliationReport() }
    let nowMillis = Int64(now().timeIntervalSince1970 * 1_000)
    let graceMillis = Int64(policy.startedGrace.components.seconds) * 1_000
    let all = try await store.read { transaction in try entries(in: transaction) }
    let candidates = all.filter { entry in
      guard entry.costSource == .pending, entry.provider == provider, entry.generationID != nil else { return false }
      return entry.outcome != .started || entry.startedMillis + graceMillis <= nowMillis
    }
    var report = ReconciliationReport()
    let batch = candidates.prefix(max(policy.maxEntries, 0)).compactMap { entry in entry.generationID.map { (id: entry.id, generation: $0) } }
    report.deferred = candidates.count - batch.count
    let results = await lookups(for: batch, using: lookup, policy: policy, sleep: sleep)
    for (id, result) in results.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
      switch result {
      case .success(let generation):
        try await store.write { transaction in try reconcile(id: id, cost: generation.cost, in: &transaction) }
        report.reconciled.append(id)
      case .failure(let error):
        report.stillPending[id] = error
        if error == .authentication { report.stoppedByAuthentication = true }
      }
    }
    return report
  }

  private static func lookups(
    for batch: [(id: UUID, generation: String)], using lookup: OpenRouterGenerationLookup, policy: ReconciliationPolicy, sleep: @escaping @Sendable (Duration) async throws -> Void
  ) async -> [UUID: Result<OpenRouterGeneration, OpenRouterGenerationError>] {
    await withTaskGroup(of: (UUID, Result<OpenRouterGeneration, OpenRouterGenerationError>).self) { group in
      var results: [UUID: Result<OpenRouterGeneration, OpenRouterGenerationError>] = [:]
      var remaining = batch[...]
      var running = 0
      while running > 0 || !remaining.isEmpty {
        while running < max(policy.maxConcurrent, 1), let entry = remaining.popFirst() {
          running += 1
          group.addTask { (entry.id, await attempts(of: entry.generation, using: lookup, policy: policy, sleep: sleep)) }
        }
        guard let (id, result) = await group.next() else { break }
        running -= 1
        results[id] = result
        if case .failure(.authentication) = result { remaining.removeAll() }
      }
      return results
    }
  }

  private static func attempts(
    of generationID: String, using lookup: OpenRouterGenerationLookup, policy: ReconciliationPolicy, sleep: @Sendable (Duration) async throws -> Void
  ) async -> Result<OpenRouterGeneration, OpenRouterGenerationError> {
    var delay = policy.backoff
    var attempt = 1
    while true {
      do {
        return .success(try await lookup.generation(id: generationID))
      } catch {
        guard error.isRetryable, attempt < policy.maxAttempts, !Task.isCancelled else { return .failure(error) }
        var wait = delay
        if case .rateLimited(let retryAfter?) = error { wait = max(wait, retryAfter) }
        do { try await sleep(min(wait, policy.maxBackoff)) } catch { return .failure(.cancelled) }
        delay = min(delay * 2, policy.maxBackoff)
        attempt += 1
      }
    }
  }
}
