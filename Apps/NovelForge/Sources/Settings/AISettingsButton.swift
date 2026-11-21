import ShadowStore
import SwiftUI

struct AISettingsButton: View {
  let store: VaultStore
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(AIServices.self) private var services
    @State private var isPresented = false
  #endif

  var body: some View {
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
      .sheet(isPresented: $isPresented) { AISettingsSheet(services: services, store: store) }
    #endif
  }

  private var label: some View {
    Label {
      Text("AI Settings", tableName: "Settings")
    } icon: {
      Image(systemName: "gearshape")
    }
  }
}

#if !os(macOS)
  private struct AISettingsSheet: View {
    let services: AIServices
    let store: VaultStore
    @Environment(SyncRuntimes.self) private var sync
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        AISettingsView(services: services, store: store)
          .navigationTitle(Text("AI Settings", tableName: "Settings"))
          .toolbar {
            ToolbarItem(placement: .topBarLeading) {
              NavigationLink {
                SyncSettingsView(sync: sync).navigationTitle(Text("Sync", tableName: "SyncSettings"))
              } label: {
                Label {
                  Text("Sync", tableName: "SyncSettings")
                } icon: {
                  Image(systemName: "arrow.triangle.2.circlepath")
                }
              }
            }
            ToolbarItem(placement: .confirmationAction) {
              Button {
                dismiss()
              } label: {
                Text("Done", tableName: "Settings")
              }
            }
          }
      }
    }
  }
#endif
