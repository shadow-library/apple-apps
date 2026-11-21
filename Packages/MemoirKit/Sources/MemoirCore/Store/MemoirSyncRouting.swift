import ShadowCore
import ShadowStore
import ShadowSync

public struct MemoirSyncRoute: Sendable, Equatable {
  public let store: MemoirStoreKind
  public let configuration: SyncConfiguration

  public init(store: MemoirStoreKind, configuration: SyncConfiguration) {
    self.store = store
    self.configuration = configuration
  }
}

/// Which of a vault's stores get a sync engine on a provider, and under which configuration. On an `.iCloud` provider the restricted store never syncs
/// and the activity store syncs only while the owner's Activity setting (`HealthSettingsRecord.activityOnICloud`) is on; elsewhere all three sync.
/// The engine's own class check stays the backstop: a route never admits a class its provider's policy refuses.
public enum MemoirSyncRouting {
  public static func routes(for policy: StorageClassPolicy, activityOnICloud: Bool, configuration: SyncConfiguration = .init()) -> [MemoirSyncRoute] {
    var closed = configuration
    closed.activityOnICloud = false
    switch policy {
    case .unrestricted:
      return MemoirStoreKind.allCases.map { MemoirSyncRoute(store: $0, configuration: closed) }
    case .iCloud:
      guard activityOnICloud else { return [MemoirSyncRoute(store: .main, configuration: closed)] }
      var admitting = configuration
      admitting.activityOnICloud = true
      return [MemoirSyncRoute(store: .main, configuration: closed), MemoirSyncRoute(store: .activity, configuration: admitting)]
    }
  }

  /// Reads the setting from the main store; an absent or unreadable settings record leaves Activity on the device.
  public static func routes(for policy: StorageClassPolicy, settingsIn main: VaultStore, configuration: SyncConfiguration = .init()) async throws(StoreError)
    -> [MemoirSyncRoute]
  {
    let activityOnICloud = try await main.read { transaction in try HealthSettings.isActivityOnICloud(in: transaction) }
    return routes(for: policy, activityOnICloud: activityOnICloud, configuration: configuration)
  }
}
