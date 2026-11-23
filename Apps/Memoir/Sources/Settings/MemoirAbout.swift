import Foundation
import ShadowAppShell

extension AboutDisclosure {
  static var memoir: [AboutDisclosure] {
    [
      .modelProvider(app: .memoir),
      AboutDisclosure(
        id: "receipts", systemImage: "doc.text.viewfinder",
        text: LocalizedStringResource("The text of a receipt goes to your AI provider only after you allow it; the photo stays in your vault.", table: "Settings")),
      AboutDisclosure(
        id: "exchange-rates", systemImage: "arrow.left.arrow.right",
        text: LocalizedStringResource(
          "While “Fetch exchange rates” is on in Settings, Memoir asks Frankfurter (api.frankfurter.dev) for the European Central Bank’s daily rates of the currencies you spend in. Only the currency codes and a date are sent, never an amount or a note; like any website, Frankfurter sees the request’s network address.",
          table: "Settings")),
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
