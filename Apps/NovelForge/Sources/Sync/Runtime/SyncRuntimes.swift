import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

/// One `SyncRuntime` per open vault, shared by every window, with the status the indicator shows. Launch starts it; the scene phase and, on the Mac, the
/// app or a window becoming active bring it to the front; the background sends what is left inside a background task; every committed local write is
/// handed to it; a silent push asks it to look for changes. A vault opened in place of another shuts the other's runtime down first; launches and
/// shutdowns apply one at a time, in order.
@MainActor
@Observable
final class SyncRuntimes {
  typealias Factory = @MainActor (VaultStore, TrustedClock) -> SyncRuntime?

  nonisolated static let activationInterval = Duration.seconds(60)
  nonisolated private static let logger = Logger(subsystem: SyncWiring.app, category: "sync")

  private(set) var status = SyncStatus.off
  /// The names of the replicas the status lists, read from the vault's replica directory when it lists any.
  private(set) var deviceNames: [ReplicaID: String] = [:]
  @ObservationIgnored private(set) var runtime: SyncRuntime?
  @ObservationIgnored private let factory: Factory?
  @ObservationIgnored private let background: SyncBackgroundWork.Runner
  @ObservationIgnored private let activationInterval: Duration
  @ObservationIgnored private var store: ObjectIdentifier?
  @ObservationIgnored private var watchers: [Task<Void, Never>] = []
  @ObservationIgnored private var changing: Task<Void, Never>?
  @ObservationIgnored private var inFront = false
  @ObservationIgnored private var lastForeground: ContinuousClock.Instant?

  /// A nil factory syncs nothing, as while XCTest hosts the app.
  init(factory: Factory?, background: @escaping SyncBackgroundWork.Runner = SyncBackgroundWork.system, activationInterval: Duration = SyncRuntimes.activationInterval) {
    self.factory = factory
    self.background = background
    self.activationInterval = activationInterval
  }

  static func live() -> SyncRuntimes {
    guard !VaultOpener.isHostedByTests else { return SyncRuntimes(factory: nil) }
    let wiring: SyncWiring
    do throws(VaultOpenError) {
      wiring = try SyncWiring.live()
    } catch {
      logger.error("Sync is off: its files have no place code=\(error.code, privacy: .public)")
      return SyncRuntimes(factory: nil)
    }
    return SyncRuntimes { store, trustedClock in
      do throws(SyncLocationError) {
        return try wiring.runtime(store: store, trustedClock: trustedClock)
      } catch {
        logger.error("Sync is off: its location file cannot be used code=\(error.code, privacy: .public)")
        return nil
      }
    }
  }

  /// Once per vault; a call for the vault being launched waits for that launch, and nil shuts the current runtime down.
  func launch(_ store: VaultStore?, trustedClock: TrustedClock) async {
    let id = store.map(ObjectIdentifier.init)
    guard id != self.store else {
      await changing?.value
      return
    }
    self.store = id
    let previous = changing
    let task = Task {
      await previous?.value
      await replace(with: store, trustedClock: trustedClock)
    }
    changing = task
    await task.value
  }

  func shutDown() async {
    await launch(nil, trustedClock: TrustedClock())
  }

  func phaseChanged(_ phase: ScenePhase) async {
    switch phase {
    case .active:
      await foreground(at: .now)
    case .background:
      inFront = false
      guard let runtime else { return }
      await background("sync-final-upload") { await runtime.background() }
    default:
      return
    }
  }

  /// The Mac stays active for days, and a catch-up (with compaction now and then) runs only on launch and foreground, so activating the app or a window
  /// counts as a foreground, at most once per `activationInterval`.
  func activated(at now: ContinuousClock.Instant = .now) async {
    if let lastForeground, now - lastForeground < activationInterval { return }
    await foreground(at: now)
  }

  /// For a silent push: false when no vault syncs, true once the sync it started is done.
  func changeNotice() async -> Bool {
    guard let runtime else { return false }
    await runtime.changeNotice()
    return true
  }

  /// Before the Mac app quits: what is unsent goes up, for at most `timeout`.
  func uploadBeforeQuitting(within timeout: Duration) async {
    guard let runtime, status != .off else { return }
    _ = await SyncBackgroundWork.bounded(timeout) { await runtime.background() }
  }

  private func foreground(at now: ContinuousClock.Instant) async {
    inFront = true
    lastForeground = now
    await runtime?.foreground()
  }

  private func replace(with store: VaultStore?, trustedClock: TrustedClock) async {
    for watcher in watchers { watcher.cancel() }
    watchers = []
    let replaced = runtime
    runtime = nil
    status = .off
    deviceNames = [:]
    await replaced?.shutdown()
    guard let store, self.store == ObjectIdentifier(store), let made = factory?(store, trustedClock) else { return }
    runtime = made
    watchers = [follow(made, of: store), forwardWrites(of: store, to: made)]
    if inFront { await made.foreground() }
    await made.start()
  }

  private func follow(_ runtime: SyncRuntime, of store: VaultStore) -> Task<Void, Never> {
    let updates = runtime.statusUpdates()
    return Task { [weak self] in
      for await status in updates {
        let names = await Self.deviceNames(for: status.listedReplicas, in: store)
        guard let self, self.runtime === runtime else { return }
        self.deviceNames = names
        self.status = status
      }
    }
  }

  /// A replica the directory does not name, or a directory that cannot be read, leaves the name out.
  nonisolated static func deviceNames(for replicas: Set<ReplicaID>, in store: VaultStore) async -> [ReplicaID: String] {
    guard !replicas.isEmpty, let directory = try? await store.read({ transaction in try ReplicaDirectory.read(in: transaction) }) else { return [:] }
    var names: [ReplicaID: String] = [:]
    for entry in directory.replicas where replicas.contains(entry.replica) {
      if let name = entry.name ?? entry.platform, !name.isEmpty { names[entry.replica] = name }
    }
    return names
  }

  private func forwardWrites(of store: VaultStore, to runtime: SyncRuntime) -> Task<Void, Never> {
    let changes = store.loggedChanges()
    return Task {
      for await _ in changes { await runtime.localWrite() }
    }
  }
}

extension SyncStatus {
  fileprivate var listedReplicas: Set<ReplicaID> {
    guard case .attentionNeeded(.keysMissing(let replicas)) = self else { return [] }
    return replicas
  }
}
