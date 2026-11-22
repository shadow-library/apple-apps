import ShadowDesignSystem
import SwiftUI

/// The export and deletion rows of Settings' "Data and privacy" (`DATA_ROWS`, `settings-screen.tsx:49-60`).
struct DataSettingsRows: View {
  var body: some View {
    NavigationLink(value: MemoirRoute.settings(.export)) {
      row(
        Text("Export your data", tableName: "Data"),
        help: Text("Everything you have logged, health data included, in formats you can open without this app.", tableName: "Data"))
    }
    NavigationLink(value: MemoirRoute.settings(.deleteVault)) {
      row(
        Text("Delete your data", tableName: "Data"),
        help: Text("Erases everything on this device and turns sync off. It cannot be stopped or undone.", tableName: "Data"))
    }
  }

  private func row(_ label: Text, help: Text) -> some View {
    VStack(alignment: .leading, spacing: Spacing.space1) {
      label
      help.shadowFont(.footnote).foregroundStyle(ShadowColor.textSecondary)
    }
  }
}
