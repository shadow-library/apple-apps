import MemoirCore
import OSLog
import ShadowAppShell
import ShadowStore
import ShadowSync
import ShadowSyncRuntime

/// Memoir's stores as sync sees them: main at the vault's location, activity and health beside it under their routes, as `MemoirSyncRouting` decides for
/// the attached storage and the owner's Activity setting. The route names are part of the stored layout and never change. Main raises its schema floor
/// to `MemoirSchema.syncFloor`, so a build that would misread its records stops syncing; activity and health, whose registries version apart, raise none.
nonisolated enum MemoirSyncRoutes {
  static let activity = storeRoute("activity")
  static let health = storeRoute("health")

  private static let logger = Logger(subsystem: AppIdentity.memoir.id, category: "sync")

  static func vault(_ stores: MemoirStores) -> SyncedVault {
    SyncedVault(primary: stores.main, schemaFloor: MemoirSchema.syncFloor, declaredRoutes: [activity, health]) { policy in await routed(stores, policy: policy) }
  }

  /// The stores beside main that sync with storage of `policy`; a settings record that cannot be read keeps Activity on the device.
  static func routed(_ stores: MemoirStores, policy: StorageClassPolicy) async -> [SyncedStore] {
    let routes: [MemoirSyncRoute]
    do throws(StoreError) {
      routes = try await MemoirSyncRouting.routes(for: policy, settingsIn: stores.main)
    } catch {
      logger.error("The Activity setting could not be read; activity stays on this device code=\(error.code, privacy: .public)")
      routes = MemoirSyncRouting.routes(for: policy, activityOnICloud: false)
    }
    return routes.compactMap { route in
      guard let name = Self.route(for: route.store) else { return nil }
      return SyncedStore(store: stores.store(route.store), route: name, configuration: route.configuration, title: title(of: route.store))
    }
  }

  static func route(for store: MemoirStoreKind) -> SyncStoreRoute? {
    switch store {
    case .main: nil
    case .activity: activity
    case .restricted: health
    }
  }

  static func title(of store: MemoirStoreKind) -> String? {
    switch store {
    case .main: nil
    case .activity: String(localized: "activity data", table: "Sync")
    case .restricted: String(localized: "health data", table: "Sync")
    }
  }

  private static func storeRoute(_ name: String) -> SyncStoreRoute {
    guard let route = SyncStoreRoute(name) else { preconditionFailure("\(name) is a valid route name") }
    return route
  }
}
