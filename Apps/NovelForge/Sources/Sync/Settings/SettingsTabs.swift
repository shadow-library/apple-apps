import Observation

/// Which tab of the Mac Settings window shows: shared by the app's scenes, so each button that opens Settings opens its own tab.
@MainActor
@Observable
final class SettingsTabs {
  enum Tab: Hashable {
    case ai
    case sync
  }

  var selected = Tab.ai
}
