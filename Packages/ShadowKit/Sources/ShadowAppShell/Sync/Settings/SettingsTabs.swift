import Observation

/// Which tab of the Mac Settings window shows: shared by the app's scenes, so each button that opens Settings opens its own tab.
@MainActor
@Observable
public final class SettingsTabs {
  /// The shell's own tabs are `ai` and `sync`; an app adds its own as further static values.
  public struct Tab: Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
      self.id = id
    }

    public static let ai = Tab("ai")
    public static let sync = Tab("sync")
  }

  public var selected = Tab.ai
  /// Set to open Keys and Devices inside the Sync tab, and how.
  public var syncKeys: SyncKeysStart?

  public init() {}
}
