#if os(macOS)
  import MemoirCore
  import ShadowAppShell
  import ShadowDesignSystem
  import SwiftUI

  struct MemoirSettingsScene: View {
    let vault: MemoirVaultModel
    let services: AIServices
    let sync: SyncRuntimes
    let effects: MemoirModuleEffects?
    @Bindable var tabs: SettingsTabs

    var body: some View {
      TabView(selection: $tabs.selected) {
        Tab(value: SettingsTabs.Tab.features) {
          NavigationStack {
            if let opened = vault.opened {
              FeaturesView(context: MemoirScreenContext(opened), effects: effects).id(ObjectIdentifier(opened.stores.main))
            } else {
              ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
          }
          .shadowTheme()
          .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
        } label: {
          MemoirFeaturesLink.label
        }
        Tab(value: SettingsTabs.Tab.ai) {
          AISettingsScene(services: services, store: vault.opened?.stores.main)
        } label: {
          Label {
            Text("AI Settings", tableName: "AI")
          } icon: {
            Image(systemName: "sparkles")
          }
        }
        Tab(value: SettingsTabs.Tab.sync) {
          NavigationStack {
            SyncSettingsView(sync: sync, keysRoute: $tabs.syncKeys)
          }
          .syncSettingsSection { MemoirSyncSettingsSection(vault: vault) }
          .environment(sync)
          .shadowTheme()
          .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
        } label: {
          Label {
            Text("Sync", tableName: "Sync")
          } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
      }
      .onDisappear { tabs.syncKeys = nil }
    }
  }
#endif
