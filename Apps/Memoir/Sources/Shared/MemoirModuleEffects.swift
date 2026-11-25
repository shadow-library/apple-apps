import Foundation
import MemoirCore
import OSLog
import Observation
import ShadowAppShell
import ShadowCore
import ShadowStore

/// What a module change means on this device, for the owner's vault only: Activity leaving iCloud reroutes sync, and Body off stops this device reading
/// Health and forgets what it had indexed. It enforces the modules (`ModuleChanges.enforce`) on every return to the foreground and whenever the vault's
/// modules change, so a quest or a Health claim from a device that had not yet seen a change follows it; a failed enforce is only logged. An enforce
/// that ends after the vault changed settles nothing. The demo's vault is never followed.
@MainActor
@Observable
final class MemoirModuleEffects {
  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "modules") }

  @ObservationIgnored private let sync: SyncRuntimes
  @ObservationIgnored private let health: MemoirHealthImports
  @ObservationIgnored private var opened: MemoirOpenedVault?
  @ObservationIgnored private var following: Task<Void, Never>?
  @ObservationIgnored private var enforcing: Task<Void, Never>?
  @ObservationIgnored private var enforcesAgain = false

  init(sync: SyncRuntimes, health: MemoirHealthImports) {
    self.sync = sync
    self.health = health
  }

  func follow(_ opened: MemoirOpenedVault?) {
    let owner = opened.flatMap { $0.isDemo ? nil : $0 }
    if let owner, let current = self.opened, current.stores.main === owner.stores.main { return }
    following?.cancel()
    following = nil
    self.opened = owner
    guard let owner else { return }
    let selections = owner.stores.main.observeReads { transaction in try MemoirModules.selection(in: transaction) }
    following = Task { [weak self] in
      do {
        for try await _ in selections {
          guard let self, !Task.isCancelled else { return }
          self.enforce()
        }
      } catch {
        guard !Task.isCancelled else { return }
        Self.logger.error("The modules stopped being followed code=\((error as? any ShadowError)?.code ?? "unknown", privacy: .public)")
      }
    }
  }

  @discardableResult
  func foregrounded() -> Task<Void, Never>? {
    enforce()
  }

  /// Follows nothing and waits for an enforce under way, as before the vault's files go.
  func stop() async {
    follow(nil)
    await enforcing?.value
  }

  /// After the owner changed the modules of `stores` here; a change to another vault than the one followed, the demo's included, means nothing here.
  func settle(_ change: ModuleChange, in stores: MemoirStores) async {
    guard let opened, opened.stores.main === stores.main else { return }
    await settle(change, opened)
  }

  /// One enforce at a time; a request made while one runs runs once more after it, against the vault followed then.
  @discardableResult
  private func enforce() -> Task<Void, Never>? {
    guard opened != nil else { return nil }
    if let enforcing {
      enforcesAgain = true
      return enforcing
    }
    let task = Task {
      repeat {
        enforcesAgain = false
        if let opened { await enforce(opened) }
      } while enforcesAgain
      enforcing = nil
    }
    enforcing = task
    return task
  }

  private func enforce(_ opened: MemoirOpenedVault) async {
    do {
      guard let change = try await MemoirScreenContext(opened).writer.modules.enforce(), self.opened?.stores.main === opened.stores.main else { return }
      await settle(change, opened)
    } catch {
      Self.logger.error("The modules could not be enforced code=\(error.code, privacy: .public)")
    }
  }

  private func settle(_ change: ModuleChange, _ opened: MemoirOpenedVault) async {
    if !change.after.contains(.body) { await health.stopReading(opened) }
    if change.activityLeavesICloud { await sync.reroute() }
  }
}
