import ShadowDesignSystem
import SwiftUI

/// The place for the recovery phrase, this library's other devices and the QR key exchange; it shows only its title until those screens exist.
struct SyncKeysSettingsView: View {
  var body: some View {
    Color.clear
      .background(ShadowColor.surfaceApp)
      .navigationTitle(Text("Keys and Devices", tableName: "SyncSettings"))
  }
}
