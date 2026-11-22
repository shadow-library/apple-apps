import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncRuntime
import SwiftUI

/// One `SyncRuntime` per store the open vault syncs, shared by every window, with the status the indicator shows: the primary's and every route's, the
/// worst of them winning. Launch starts the primary; its routes start once it attaches a location and follow the app's `SyncedVault.routes` for that
/// location's class policy. The scene phase and, on the Mac, the app or a window becoming active bring them to the front, as worker mode keeps them on a
/// Mac with no window; the background sends what is left inside a background task; every committed local write is handed to its store's runtime; a silent
/// push asks them to look for changes. A vault opened in place of another shuts the other's runtimes down first; launches, reroutes and shutdowns apply
/// one at a time, in order.
@MainActor
@Observable
public final class SyncRuntimes {
  public typealias Factory = @MainActor (SyncedStore, TrustedClock) -> SyncRuntime?

  public nonisolated static let activationInterval = Duration.seconds(60)
  nonisolated private static let logger = Logger(category: "sync")

  /// The app whose vault syncs: its words on the sync screens, and its keychain and defaults names.
  public let identity: AppIdentity
  public private(set) var status = SyncStatus.off
  /// The names of the replicas the status lists, read from the replica directory of the store it comes from.
  public private(set) var deviceNames: [ReplicaID: String] = [:]
  /// The data a routed store's status concerns when it is the one shown and needs attention; nil when it concerns the vault as a whole.
  public private(set) var attentionScope: String?
  /// The primary store's runtime, which the sync settings and key screens drive.
  public private(set) var runtime: SyncRuntime?
  private(set) var routed: [SyncStoreRoute: RoutedRuntime] = [:]
  /// The routes whose stores sync now beside the primary.
  public var syncingRoutes: Set<SyncStoreRoute> { Set(routed.keys) }
  /// False while the open vault declares routes: a move carries only the primary's store, so the primary's runtime refuses to move or follow a move.
  public private(set) var canMoveVault = true
  private var primaryStatus = SyncStatus.off
  private var primaryNames: [ReplicaID: String] = [:]
  /// What the sync settings read and connect through; nil when nothing syncs.
  @ObservationIgnored let wiring: SyncWiring?
  @ObservationIgnored private let factory: Factory?
  @ObservationIgnored private let background: SyncBackgroundWork.Runner
  @ObservationIgnored private let activationInterval: Duration
  @ObservationIgnored private var store: ObjectIdentifier?
  @ObservationIgnored private var vault: SyncedVault?
  @ObservationIgnored private var trustedClock = TrustedClock()
  @ObservationIgnored private var watchers: [Task<Void, Never>] = []
  @ObservationIgnored private var changing: Task<Void, Never>?
  @ObservationIgnored private var isReroutePending = false
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

  /// Runtimes from `factory` rather than the app's own wiring, as in an app's tests; the sync settings then have nothing to connect through.
  public convenience init(identity: AppIdentity, factory: Factory?) {
    self.init(identity: identity, factory: factory, wiring: nil)
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
      factory: { synced, trustedClock in
        do throws(SyncLocationError) {
          return try wiring.runtime(for: synced, trustedClock: trustedClock)
        } catch {
          logger.error("Sync is off: its location file cannot be used code=\(error.code, privacy: .public)")
          return nil
        }
      }, wiring: wiring)
  }

  /// A vault of one store, with no routes.
  public func launch(_ store: VaultStore?, trustedClock: TrustedClock) async {
    await launch(store.map { SyncedVault(primary: $0) }, trustedClock: trustedClock)
  }

  /// Once per vault, told apart by its primary store; a call for the vault being launched waits for that launch, and nil shuts every runtime down.
  public func launch(_ vault: SyncedVault?, trustedClock: TrustedClock) async {
    let id = vault.map { ObjectIdentifier($0.primary) }
    guard id != self.store else {
      await changing?.value
      return
    }
    self.store = id
    await enqueue { await self.replace(with: vault, trustedClock: trustedClock) }
  }

  public func shutDown() async {
    await launch(nil as SyncedVault?, trustedClock: TrustedClock())
  }

  /// Asks the vault's routes again, as after the app changed a setting they depend on; returns once the routes it names run and the others stopped.
  public func reroute() async {
    await enqueue { await self.applyRoutes() }
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

  /// For a silent push: false when no vault syncs, true once the syncs it started are done.
  public func changeNotice() async -> Bool {
    guard runtime != nil else { return false }
    await Self.each(runtimes) { await $0.changeNotice() }
    return true
  }

  /// Before the Mac app quits: what is unsent goes up, for at most `timeout`.
  public func uploadBeforeQuitting(within timeout: Duration) async {
    let runtimes = runtimes
    guard !runtimes.isEmpty, status != .off else { return }
    _ = await SyncBackgroundWork.bounded(timeout) { await Self.each(runtimes) { await $0.background() } }
  }

  private var runtimes: [SyncRuntime] {
    (runtime.map { [$0] } ?? []) + routed.keys.sorted { $0.name < $1.name }.compactMap { routed[$0]?.runtime }
  }

  private func enterBackground() async {
    inFront = false
    let runtimes = runtimes
    guard !runtimes.isEmpty else { return }
    await background("sync-final-upload") { await Self.each(runtimes) { await $0.background() } }
  }

  private func foreground(at now: ContinuousClock.Instant) async {
    inFront = true
    lastForeground = now
    await Self.each(runtimes) { await $0.foreground() }
  }

  private static func each(_ runtimes: [SyncRuntime], _ body: @escaping @Sendable (SyncRuntime) async -> Void) async {
    await withDiscardingTaskGroup { group in
      for runtime in runtimes { group.addTask { await body(runtime) } }
    }
  }

  private func enqueue(_ work: @escaping @MainActor () async -> Void) async {
    let previous = changing
    let task = Task {
      await previous?.value
      await work()
    }
    changing = task
    await task.value
  }

  private func replace(with vault: SyncedVault?, trustedClock: TrustedClock) async {
    for watcher in watchers { watcher.cancel() }
    watchers = []
    let replaced = runtime
    runtime = nil
    self.vault = nil
    primaryStatus = .off
    primaryNames = [:]
    canMoveVault = true
    await stopRoutes { _, _ in true }
    summarize()
    await replaced?.shutdown()
    guard let vault, self.store == ObjectIdentifier(vault.primary), let made = factory?(vault.primaryStore, trustedClock) else { return }
    runtime = made
    self.vault = vault
    canMoveVault = vault.declaredRoutes.isEmpty
    self.trustedClock = trustedClock
    watchers = [follow(made, of: vault.primary), forwardWrites(of: vault.primary, to: made)]
    if inFront { await made.foreground() }
    await made.start()
    await applyRoutes()
  }

  /// A primary status update may come from a new location, a provider changed or a setting the routes read that arrived by sync, so each one asks the
  /// routes again; updates that arrive while one such pass waits join it.
  private func requestReroute() {
    guard !isReroutePending else { return }
    isReroutePending = true
    Task {
      await enqueue {
        self.isReroutePending = false
        await self.applyRoutes()
      }
    }
  }

  private func applyRoutes() async {
    guard let primary = runtime, let vault else { return await stopRoutes { _, _ in true } }
    let attached = await primary.attachedLocation
    var wanted: [SyncStoreRoute: SyncedStore] = [:]
    if let attached {
      for synced in await vault.routes(attached.classPolicy) {
        guard let route = synced.route, vault.declaredRoutes.contains(route), synced.store !== vault.primary, wanted[route] == nil else {
          Self.logger.fault("A synced vault named an undeclared route, the primary store or one route twice")
          continue
        }
        wanted[route] = synced
      }
    }
    guard runtime === primary, let location = attached?.location else { return await stopRoutes { _, _ in true } }
    await stopRoutes { route, running in !running.serves(wanted[route], at: location) }
    for route in wanted.keys.sorted(by: { $0.name < $1.name }) where routed[route] == nil {
      guard let synced = wanted[route], let made = factory?(synced, trustedClock) else { continue }
      let running = RoutedRuntime(synced: synced, location: location, runtime: made)
      routed[route] = running
      running.watchers = [follow(made, route: route, of: synced.store), forwardWrites(of: synced.store, to: made), Self.launch(made, inFront: inFront)]
      Self.logger.info("Started syncing a routed store route=\(route.name, privacy: .public)")
    }
  }

  /// A route's first run may take minutes against a large store, so nothing waits for it: a reroute returns as soon as the route is set up.
  private static func launch(_ runtime: SyncRuntime, inFront: Bool) -> Task<Void, Never> {
    Task {
      if inFront { await runtime.foreground() }
      await runtime.start()
    }
  }

  /// A stopped route's store keeps every record. Sending stops at once (only a put already issued finishes), and this returns once the route's run in
  /// flight is over, so no new runtime ever shares the store with it.
  private func stopRoutes(where shouldStop: (SyncStoreRoute, RoutedRuntime) -> Bool) async {
    let stopped = routed.filter { shouldStop($0.key, $0.value) }
    guard !stopped.isEmpty else { return }
    for (route, running) in stopped {
      for watcher in running.watchers { watcher.cancel() }
      routed[route] = nil
      Self.logger.info("Stopped syncing a routed store route=\(route.name, privacy: .public)")
    }
    summarize()
    await Self.each(stopped.values.map(\.runtime)) { await $0.stop() }
  }

  private func follow(_ runtime: SyncRuntime, of store: VaultStore) -> Task<Void, Never> {
    let updates = runtime.statusUpdates()
    return Task { [weak self] in
      for await status in updates {
        let names = await Self.deviceNames(for: status.listedReplicas, in: store)
        guard let self, self.runtime === runtime else { return }
        let keysArrived = self.primaryStatus.waitsForKeys && !status.waitsForKeys
        self.primaryNames = names
        self.primaryStatus = status
        self.summarize()
        if keysArrived { self.keysArrived() }
        self.requestReroute()
      }
    }
  }

  /// Routes share the primary's ring, so a key the primary now holds is theirs too; they look at once rather than at their next key check.
  private func keysArrived() {
    for running in routed.values {
      let runtime = running.runtime
      Task { await runtime.keysImported() }
    }
  }

  private func follow(_ runtime: SyncRuntime, route: SyncStoreRoute, of store: VaultStore) -> Task<Void, Never> {
    let updates = runtime.statusUpdates()
    return Task { [weak self] in
      for await status in updates {
        let names = await Self.deviceNames(for: status.listedReplicas, in: store)
        guard let self, let running = self.routed[route], running.runtime === runtime else { return }
        running.status = status
        running.deviceNames = names
        self.summarize()
      }
    }
  }

  private func summarize() {
    let routes = routed.keys.sorted { $0.name < $1.name }.compactMap { routed[$0] }
    let statuses = [primaryStatus] + routes.map(\.status)
    guard let winner = Self.worst(statuses) else { return }
    let route = winner == 0 ? nil : routes[winner - 1]
    status = statuses[winner]
    deviceNames = route?.deviceNames ?? primaryNames
    if case .attentionNeeded = status { attentionScope = route?.synced.title } else { attentionScope = nil }
  }

  /// The index of the status to show: attention before syncing before up to date before off, among attentions the one that stops the most, and the first
  /// of equals, so the primary's wins a tie.
  nonisolated static func worst(_ statuses: [SyncStatus]) -> Int? {
    statuses.indices.min { (statuses[$0].rank, $0) < (statuses[$1].rank, $1) }
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

/// A routed store's runtime and the location it was started for: a new location, store or configuration starts a new one.
@MainActor
final class RoutedRuntime {
  let synced: SyncedStore
  let location: SyncLocation
  let runtime: SyncRuntime
  var watchers: [Task<Void, Never>] = []
  var status = SyncStatus.off
  var deviceNames: [ReplicaID: String] = [:]

  init(synced: SyncedStore, location: SyncLocation, runtime: SyncRuntime) {
    self.synced = synced
    self.location = location
    self.runtime = runtime
  }

  func serves(_ wanted: SyncedStore?, at location: SyncLocation) -> Bool {
    guard let wanted else { return false }
    return wanted.store === synced.store && wanted.configuration == synced.configuration && wanted.title == synced.title && location == self.location
  }
}

extension SyncStatus {
  fileprivate var listedReplicas: Set<ReplicaID> {
    guard case .attentionNeeded(.keysMissing(let replicas)) = self else { return [] }
    return replicas
  }

  fileprivate var waitsForKeys: Bool {
    switch self {
    case .attentionNeeded(.awaitingKey), .attentionNeeded(.writingKeyMissing), .attentionNeeded(.keysMissing): true
    default: false
    }
  }

  fileprivate nonisolated var rank: Int {
    switch self {
    case .attentionNeeded(let reason):
      switch reason.stops {
      case .everything: 0
      case .uploads: 1
      case .downloads: 2
      case .nothing: 3
      }
    case .syncing: 4
    case .upToDate: 5
    case .off: 6
    }
  }
}
