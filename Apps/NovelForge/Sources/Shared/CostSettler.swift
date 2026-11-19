import Foundation
import OSLog
import ShadowAI
import ShadowStore

@MainActor
final class CostSettler {
  typealias Pass = @concurrent @Sendable () async throws(StoreError) -> ReconciliationReport

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "costs")

  private let pass: Pass
  private let cooldown: Duration
  private let clock: () -> Date
  private var running: Task<Void, Never>?
  private var generation = 0
  private var requeued = false
  private var launched = false
  private var coolingUntil = Date.distantPast

  init(cooldown: Duration = .seconds(60), clock: @escaping () -> Date = { Date() }, pass: @escaping Pass) {
    self.cooldown = cooldown
    self.clock = clock
    self.pass = pass
  }

  convenience init(
    store: VaultStore, lookup: OpenRouterGenerationLookup, policy: ReconciliationPolicy = .init(), cooldown: Duration = .seconds(60),
    clock: @escaping () -> Date = { Date() }, now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.init(cooldown: cooldown, clock: clock) { () async throws(StoreError) -> ReconciliationReport in
      try await Ledger.reconcilePending(in: store, using: lookup, policy: policy, now: now, sleep: sleep)
    }
  }

  var isSettling: Bool { running != nil }

  private var isCooling: Bool { clock() < coolingUntil }

  func settleLeftovers() {
    guard !launched else { return }
    launched = true
    settle()
  }

  func settle() {
    guard !isCooling else { return }
    guard running == nil else {
      requeued = true
      return
    }
    generation += 1
    let token = generation
    running = Task { [weak self] in
      repeat {
        guard let self, generation == token else { return }
        requeued = false
        await settleOnce()
      } while self?.shouldRepeat(token) == true
      self?.finish(token)
    }
  }

  func shutDown() {
    running?.cancel()
    running = nil
    generation += 1
    requeued = false
  }

  private func shouldRepeat(_ token: Int) -> Bool { generation == token && requeued && !isCooling && !Task.isCancelled }

  private func finish(_ token: Int) {
    guard generation == token else { return }
    running = nil
  }

  private func settleOnce() async {
    do throws(StoreError) {
      let report = try await pass()
      if report.reconciled.isEmpty && !report.stillPending.isEmpty { cool() }
      guard !report.reconciled.isEmpty || !report.stillPending.isEmpty else { return }
      Self.logger.info(
        "Settled pending costs reconciled=\(report.reconciled.count, privacy: .public) pending=\(report.stillPending.count, privacy: .public) deferred=\(report.deferred, privacy: .public)"
      )
      if report.stoppedByAuthentication { Self.logger.notice("Pending costs stay pending: OpenRouter refused the key") }
    } catch {
      cool()
      Self.logger.error("Pending costs could not be settled code=\(error.code, privacy: .public)")
    }
  }

  private func cool() {
    coolingUntil = clock().addingTimeInterval(TimeInterval(cooldown.components.seconds))
  }
}
