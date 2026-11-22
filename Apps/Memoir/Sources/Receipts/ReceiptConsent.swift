import Foundation
import ShadowAI
import ShadowAppShell

extension ConsentDisclosure {
  nonisolated static let memoirReceipts = ConsentDisclosure(
    id: ReceiptStructuring.consent.disclosure, dataClass: ReceiptStructuring.consent.dataClass,
    title: { String(localized: "The text of your receipts", table: "Receipts") },
    explanation: { provider in
      String(
        localized:
          "To fill in an expense from a receipt, Memoir reads the photo’s text on this device and sends that text to \(provider). The photo itself never leaves your vault. \(provider) processes the text under its own terms.",
        table: "Receipts")
    })
}
