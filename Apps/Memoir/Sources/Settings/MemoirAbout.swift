import Foundation
import ShadowAppShell

extension AboutDisclosure {
  static var memoir: [AboutDisclosure] {
    [
      .modelProvider(app: .memoir),
      AboutDisclosure(
        id: "receipts", systemImage: "doc.text.viewfinder",
        text: LocalizedStringResource("The text of a receipt goes to your AI provider only after you allow it; the photo stays in your vault.", table: "Settings")),
      .sync(app: .memoir),
      .keychain(app: .memoir),
      AboutDisclosure(
        id: "health", systemImage: "heart",
        text: LocalizedStringResource(
          "Health data never syncs through iCloud, and activity data does only while you turn it on in Sync settings. Other storage you choose receives both, encrypted like the rest of your vault.",
          table: "Settings")),
      .nothingElse(app: .memoir),
    ]
  }
}
