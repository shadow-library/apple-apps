import ShadowDesignSystem
import SwiftUI

/// "Data and privacy" (`settings-screen.tsx:261-283`), where export and deleting the vault belong; notification preferences and billing went with the
/// server, and coaching consent is in AI Settings.
struct SettingsDataSection: View {
  var body: some View {
    Section {
      Text("Your log is private by default. Nothing is published or compared with anyone.", tableName: "Settings")
        .shadowFont(.subheadline)
        .foregroundStyle(ShadowColor.textSecondary)
    } header: {
      Text("Data and privacy", tableName: "Settings")
    }
  }
}
