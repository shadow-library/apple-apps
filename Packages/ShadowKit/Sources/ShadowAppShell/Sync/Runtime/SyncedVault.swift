import ShadowStore
import ShadowSync
import ShadowSyncRuntime

/// One store a vault syncs: the primary at the vault's location itself, any other under its route at the same location.
public nonisolated struct SyncedStore: Sendable {
  public let store: VaultStore
  public let route: SyncStoreRoute?
  public let configuration: SyncConfiguration
  /// The store's data inside a sentence, such as "activity data", named when sync needs attention for this store alone; nil for the vault as a whole.
  public let title: String?
  /// For the primary: the routes its vault declares, which its runtime takes as `SyncStartupEnvironment.routedStores`.
  public let routedBeside: Set<SyncStoreRoute>

  public init(store: VaultStore, route: SyncStoreRoute? = nil, configuration: SyncConfiguration = .init(), title: String? = nil) {
    self.init(store: store, route: route, configuration: configuration, title: title, routedBeside: [])
  }

  init(store: VaultStore, route: SyncStoreRoute?, configuration: SyncConfiguration, title: String?, routedBeside: Set<SyncStoreRoute>) {
    self.store = store
    self.route = route
    self.configuration = configuration
    self.title = title
    self.routedBeside = routedBeside
  }
}

/// What an app syncs from its vault: the primary store, which attaches, detaches and holds the keys, and the stores routed beside it. `declaredRoutes`
/// names every route the vault may ever sync, whether or not it runs now, since a stopped route still has history at the location; a vault that
/// declares any cannot move yet. `routes` is asked for the attached location's class policy whenever the primary's status changes and whenever the app
/// calls `SyncRuntimes.reroute()`; it names only declared routes, and one it stops naming stops syncing and keeps its records.
public nonisolated struct SyncedVault: Sendable {
  public typealias Routes = @Sendable (StorageClassPolicy) async -> [SyncedStore]

  public let primary: VaultStore
  public let declaredRoutes: Set<SyncStoreRoute>
  public let routes: Routes

  public init(primary: VaultStore, declaredRoutes: Set<SyncStoreRoute> = [], routes: @escaping Routes = { _ in [] }) {
    self.primary = primary
    self.declaredRoutes = declaredRoutes
    self.routes = routes
  }

  var primaryStore: SyncedStore {
    SyncedStore(store: primary, route: nil, configuration: .init(), title: nil, routedBeside: declaredRoutes)
  }
}
