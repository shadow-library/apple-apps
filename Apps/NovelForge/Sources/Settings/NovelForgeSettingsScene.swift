import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

struct NovelForgeSettingsScene: View {
  let vault: NovelForgeVault
  let services: AIServices
  let sync: SyncRuntimes
  #if os(macOS)
    let jobs: JobRuntimes
    let worker: WorkerModel
  #endif
  @Bindable var tabs: SettingsTabs

  var body: some View {
    TabView(selection: $tabs.selected) {
      Tab(value: SettingsTabs.Tab.ai) {
        AISettingsScene(services: services, store: vault.store)
      } label: {
        Label {
          Text("AI Settings", tableName: "Settings")
        } icon: {
          Image(systemName: "sparkles")
        }
      }
      Tab(value: SettingsTabs.Tab.sync) {
        NavigationStack {
          SyncSettingsView(sync: sync, keysRoute: $tabs.syncKeys)
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
      #if os(macOS)
        Tab(value: SettingsTabs.Tab.worker) {
          DevicesAndWorkerView(store: vault.store, jobs: jobs, worker: worker)
            .shadowTheme()
            .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
        } label: {
          Label {
            Text("Devices and Worker", tableName: "Worker")
          } icon: {
            Image(systemName: "macbook.and.iphone")
          }
        }
      #endif
      Tab(value: SettingsTabs.Tab.about) {
        NavigationStack {
          AboutView(identity: .novelForge, disclosures: AboutDisclosure.novelForge)
        }
        .shadowTheme()
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 640)
      } label: {
        AboutLabel(identity: .novelForge)
      }
    }
    .onDisappear { tabs.syncKeys = nil }
  }
}
