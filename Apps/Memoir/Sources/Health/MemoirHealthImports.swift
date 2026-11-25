import Foundation
import MemoirCore
import OSLog
import ShadowAppShell
import ShadowStore

/// Reads Health when a window opens the vault, each time the scene becomes active and when protected data becomes available, on the vault's designated
/// reader only; never from a silent push. Background delivery is not used. While Body is off nothing is read: this device instead forgets the metrics it
/// read and what it had indexed, without asking HealthKit anything, so turning Body on again starts from a metric turned on then.
@MainActor
final class MemoirHealthImports {
  private static let logger = Logger(subsystem: AppIdentity.memoir.id, category: "health")

  private let environment: @MainActor () -> HealthEnvironment
  private var running: Task<Void, Never>?

  init(environment: @escaping @MainActor () -> HealthEnvironment = { .live() }) {
    self.environment = environment
  }

  @discardableResult
  func foregrounded(_ opened: MemoirOpenedVault?) -> Task<Void, Never>? {
    guard let opened, !opened.isDemo, running == nil else { return nil }
    let environment = environment()
    guard !environment.preferences.metrics.isEmpty else { return nil }
    let task = Task {
      await importOrStop(opened, environment: environment)
      running = nil
    }
    running = task
    return task
  }

  /// After Body was turned off here or arrived off by sync.
  func stopReading(_ opened: MemoirOpenedVault) async {
    guard !opened.isDemo else { return }
    await stop(opened, environment: environment())
  }

  private func importOrStop(_ opened: MemoirOpenedVault, environment: HealthEnvironment) async {
    let selection: ModuleSelection
    do {
      selection = try await opened.stores.main.read { transaction in try MemoirModules.selection(in: transaction) }
    } catch {
      return Self.logger.error("The modules could not be read before a Health import code=\(error.code, privacy: .public)")
    }
    guard selection.contains(.body) else { return await stop(opened, environment: environment) }
    guard environment.canRead else { return }
    _ = await HealthImportRunner(environment: environment, stores: opened.stores, clock: opened.clock).run()
  }

  private func stop(_ opened: MemoirOpenedVault, environment: HealthEnvironment) async {
    guard !environment.preferences.metrics.isEmpty else { return }
    environment.preferences.metrics = []
    do {
      try await HealthImport.forgetLocalState(in: opened.stores)
    } catch {
      Self.logger.error("What this device indexed from Health could not be forgotten code=\(error.code, privacy: .public)")
    }
  }
}
