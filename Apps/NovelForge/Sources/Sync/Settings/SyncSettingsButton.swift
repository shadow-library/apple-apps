import SwiftUI

struct SyncSettingsButton: View {
  #if os(macOS)
    @Environment(SettingsTabs.self) private var tabs
    @Environment(\.openSettings) private var openSettings
  #else
    @Environment(SyncRuntimes.self) private var sync
    @State private var isPresented = false
  #endif

  var body: some View {
    #if os(macOS)
      Button {
        tabs.selected = .sync
        tabs.syncKeys = nil
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
      .sheet(isPresented: $isPresented) { SyncSettingsSheet(sync: sync) }
    #endif
  }

  private var label: some View {
    Label {
      Text("Sync Settings", tableName: "SyncSettings")
    } icon: {
      Image(systemName: "arrow.triangle.2.circlepath")
    }
  }
}

#if !os(macOS)
  struct SyncSettingsSheet: View {
    let sync: SyncRuntimes
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        SyncSettingsView(sync: sync)
          .navigationTitle(Text("Sync", tableName: "SyncSettings"))
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button {
                dismiss()
              } label: {
                Text("Done", tableName: "SyncSettings")
              }
            }
          }
      }
    }
  }
#endif
