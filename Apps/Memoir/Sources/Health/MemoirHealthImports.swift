import Foundation
import MemoirCore

/// Reads Health when a window opens the vault, each time the scene becomes active and when protected data becomes available, on the vault's designated
/// reader only; never from a silent push. Background delivery is not used.
@MainActor
final class MemoirHealthImports {
  private var running: Task<Void, Never>?

  func foregrounded(_ opened: MemoirOpenedVault?) {
    guard let opened, running == nil else { return }
    let environment = HealthEnvironment.live()
    guard environment.canRead, !environment.preferences.metrics.isEmpty else { return }
    let runner = HealthImportRunner(environment: environment, stores: opened.stores, clock: opened.clock)
    running = Task {
      _ = await runner.run()
      running = nil
    }
  }
}
