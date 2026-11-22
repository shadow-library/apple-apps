import ShadowAppShell
import ShadowStore
import SwiftUI

extension SettingsTabs.Tab {
  static let worker = SettingsTabs.Tab("worker")
}

extension AISettingsButton where Links == DevicesAndWorkerLink {
  init(store: VaultStore) {
    self.init(store: store) { DevicesAndWorkerLink(store: $0) }
  }
}

/// Leads from the AI settings sheet to the vault's devices and worker; the Mac shows them in a tab of Settings instead.
struct DevicesAndWorkerLink: View {
  let store: VaultStore
  #if !os(macOS)
    @Environment(JobRuntimes.self) private var jobs
  #endif

  var body: some View {
    #if !os(macOS)
      NavigationLink {
        DevicesAndWorkerView(store: store, jobs: jobs).navigationTitle(Text("Devices and Worker", tableName: "Worker"))
      } label: {
        Label {
          Text("Devices and Worker", tableName: "Worker")
        } icon: {
          Image(systemName: "macbook.and.iphone")
        }
      }
    #endif
  }
}
