import ShadowDesignSystem
import SwiftUI

struct NovelForgeSettingsScene: View {
  let vault: VaultModel
  let services: AIServices
  let sync: SyncRuntimes
  @Bindable var tabs: SettingsTabs

  var body: some View {
    TabView(selection: $tabs.selected) {
      Tab(value: SettingsTabs.Tab.ai) {
        AISettingsScene(vault: vault, services: services)
      } label: {
        Label {
          Text("AI Settings", tableName: "Settings")
        } icon: {
          Image(systemName: "sparkles")
        }
      }
      Tab(value: SettingsTabs.Tab.sync) {
        NavigationStack {
          SyncSettingsView(sync: sync)
        }
        .shadowTheme()
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
      } label: {
        Label {
          Text("Sync", tableName: "SyncSettings")
        } icon: {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
      }
    }
  }
}
