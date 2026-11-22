import ShadowStore
import SwiftUI

/// Opens AI settings: the AI tab of Settings on the Mac, a sheet elsewhere whose toolbar also leads to Sync and to whatever `links` the app adds.
public struct AISettingsButton<Links: View>: View {
  let store: VaultStore
  let links: (VaultStore) -> Links
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(AIServices.self) private var services
    @State private var isPresented = false
  #endif

  public init(store: VaultStore, @ViewBuilder links: @escaping (VaultStore) -> Links) {
    self.store = store
    self.links = links
  }

  public var body: some View {
    #if os(macOS)
      Button {
        tabs.selected = .ai
        openSettings()
      } label: {
        label
      }
    #else
      Button {
        isPresented = true
      } label: {
        label
      }
      .sheet(isPresented: $isPresented) { AISettingsSheet(services: services, store: store, links: links(store)) }
    #endif
  }

  private var label: some View {
    Label {
      Text("AI Settings", tableName: "AISettings", bundle: .module)
    } icon: {
      Image(systemName: "gearshape")
    }
  }
}

#if !os(macOS)
  private struct AISettingsSheet<Links: View>: View {
    let services: AIServices
    let store: VaultStore
    let links: Links
    @Environment(SyncRuntimes.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        AISettingsView(services: services, store: store)
          .navigationTitle(Text("AI Settings", tableName: "AISettings", bundle: .module))
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              NavigationLink {
                SyncSettingsView(sync: sync).navigationTitle(Text("Sync", tableName: "SyncSettings", bundle: .module))
              } label: {
                Label {
                  Text("Sync", tableName: "SyncSettings", bundle: .module)
                } icon: {
                  Image(systemName: "arrow.triangle.2.circlepath")
                }
              }
            }
            ToolbarItem(placement: .topBarLeading) { links }
            ToolbarItem(placement: .confirmationAction) {
              Button {
                dismiss()
              } label: {
                Text("Done", tableName: "AISettings", bundle: .module)
              }
            }
          }
      }
    }
  }
#endif
