import ShadowStore
import SwiftUI

struct AISettingsButton: View {
  let store: VaultStore
  #if !os(macOS)
    @Environment(AIServices.self) private var services
    @State private var isPresented = false
  #endif

  var body: some View {
    #if os(macOS)
      SettingsLink { label }
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        AISettingsView(services: services, store: store)
          .navigationTitle(Text("AI Settings", tableName: "Settings"))
          .toolbar {
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
