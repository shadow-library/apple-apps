import ShadowAppShell
import ShadowDesignSystem
import ShadowStore
import SwiftUI

extension SettingsTabs.Tab {
  static let worker = SettingsTabs.Tab("worker")
}

extension AISettingsButton where Links == NovelForgeSettingsLinks {
  init(store: VaultStore) {
    self.init(store: store) { NovelForgeSettingsLinks(store: $0) }
  }
}

/// The AI settings sheet's further pages on iPhone and iPad; the Mac shows them in tabs of Settings instead.
struct NovelForgeSettingsLinks: View {
  let store: VaultStore

  var body: some View {
    #if !os(macOS)
      HStack(spacing: Spacing.space3) {
        DevicesAndWorkerLink(store: store)
        NavigationLink {
          AboutView(identity: .novelForge, disclosures: AboutDisclosure.novelForge)
        } label: {
          AboutLabel(identity: .novelForge)
        }
      }
    #endif
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
