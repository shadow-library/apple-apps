import SwiftUI

/// A section an app adds to Sync Settings under the location, wherever the screen shows: in the Mac's Settings window, a sheet or a pushed page.
struct SyncSettingsSection {
  let content: @MainActor () -> AnyView
}

extension EnvironmentValues {
  @Entry var syncSettingsSection: SyncSettingsSection?
}

extension View {
  /// Every Sync Settings screen inside this view shows `content` below the sync location while no connect flow is open.
  public func syncSettingsSection<Content: View>(@ViewBuilder _ content: @escaping @MainActor () -> Content) -> some View {
    environment(\.syncSettingsSection, SyncSettingsSection { AnyView(content()) })
  }
}
