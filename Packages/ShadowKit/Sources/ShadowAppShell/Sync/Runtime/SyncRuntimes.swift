import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

/// One `SyncRuntime` per open vault, shared by every window, with the status the indicator shows. Launch starts it; the scene phase and, on the Mac, the
/// app or a window becoming active bring it to the front, as worker mode keeps it on a Mac with no window; the background sends what is left inside a
/// background task; every committed local write is handed to it; a silent push asks it to look for changes. A vault opened in place of another shuts the
/// other's runtime down first; launches and shutdowns apply one at a time, in order.
@MainActor
@Observable
public final class SyncRuntimes {
  public typealias Factory = @MainActor (VaultStore, TrustedClock) -> SyncRuntime?

  public nonisolated static let activationInterval = Duration.seconds(60)
  nonisolated private static let logger = Logger(category: "sync")

  /// The app whose vault syncs: its words on the sync screens, and its keychain and defaults names.
  public let identity: AppIdentity
  public private(set) var status = SyncStatus.off
  /// The names of the replicas the status lists, read from the vault's replica directory when it lists any.
  public private(set) var deviceNames: [ReplicaID: String] = [:]
  public private(set) var runtime: SyncRuntime?
  /// What the sync settings read and connect through; nil when nothing syncs.
  @ObservationIgnored let wiring: SyncWiring?
  @ObservationIgnored private let factory: Factory?
  @ObservationIgnored private let background: SyncBackgroundWork.Runner
  @ObservationIgnored private let activationInterval: Duration
  @ObservationIgnored private var store: ObjectIdentifier?
  @ObservationIgnored private var watchers: [Task<Void, Never>] = []
  @ObservationIgnored private var changing: Task<Void, Never>?
  @ObservationIgnored private var inFront = false
  @ObservationIgnored private var sceneInFront = false
  @ObservationIgnored private var keptInFront = false
  @ObservationIgnored private var lastForeground: ContinuousClock.Instant?

  /// A nil factory syncs nothing, as while XCTest hosts the app.
  init(
    identity: AppIdentity, factory: Factory?, wiring: SyncWiring? = nil, background: @escaping SyncBackgroundWork.Runner = SyncBackgroundWork.system,
    activationInterval: Duration = SyncRuntimes.activationInterval
  ) {
    self.identity = identity
    self.factory = factory
    self.wiring = wiring
    self.background = background
    self.activationInterval = activationInterval
  }

  public static func live(identity: AppIdentity) -> SyncRuntimes {
    guard !VaultDirectory.isHostedByTests else { return SyncRuntimes(identity: identity, factory: nil) }
    let wiring: SyncWiring
    do throws(VaultOpenError) {
      wiring = try SyncWiring.live(identity: identity)
    } catch {
      logger.error("Sync is off: its files have no place code=\(error.code, privacy: .public)")
      return SyncRuntimes(identity: identity, factory: nil)
    }
    return SyncRuntimes(
      identity: identity,
      factory: { store, trustedClock in
        do throws(SyncLocationError) {
          return try wiring.runtime(store: store, trustedClock: trustedClock)
        } catch {
          logger.error("Sync is off: its location file cannot be used code=\(error.code, privacy: .public)")
          return nil
        }
      }, wiring: wiring)
  }

  /// Once per vault; a call for the vault being launched waits for that launch, and nil shuts the current runtime down.
  public func launch(_ store: VaultStore?, trustedClock: TrustedClock) async {
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

  public func shutDown() async {
    await launch(nil, trustedClock: TrustedClock())
  }

  public func phaseChanged(_ phase: ScenePhase) async {
    switch phase {
    case .active:
      sceneInFront = true
      await foreground(at: .now)
    case .background:
      sceneInFront = false
      guard !keptInFront else { return }
      await enterBackground()
    default:
      return
    }
  }

  #if os(macOS)
    /// While the Mac runs the vault's jobs it syncs as in front with no window open, so a job asked for on another device reaches it within a poll.
    public func keepInFront(_ kept: Bool) async {
      guard kept != keptInFront else { return }
      keptInFront = kept
      if kept {
        await foreground(at: .now)
      } else if !sceneInFront {
        await enterBackground()
      }
    }
  #endif

  /// The Mac stays active for days, and a catch-up (with compaction now and then) runs only on launch and foreground, so activating the app or a window
  /// counts as a foreground, at most once per `activationInterval`.
  public func activated(at now: ContinuousClock.Instant = .now) async {
    if let lastForeground, now - lastForeground < activationInterval { return }
    await foreground(at: now)
  }

  /// For a silent push: false when no vault syncs, true once the sync it started is done.
  public func changeNotice() async -> Bool {
    guard let runtime else { return false }
    await runtime.changeNotice()
    return true
  }

  /// Before the Mac app quits: what is unsent goes up, for at most `timeout`.
  public func uploadBeforeQuitting(within timeout: Duration) async {
    guard let runtime, status != .off else { return }
    _ = await SyncBackgroundWork.bounded(timeout) { await runtime.background() }
  }

  private func enterBackground() async {
    inFront = false
    guard let runtime else { return }
    await background("sync-final-upload") { await runtime.background() }
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
  public nonisolated static func deviceNames(for replicas: Set<ReplicaID>, in store: VaultStore) async -> [ReplicaID: String] {
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
