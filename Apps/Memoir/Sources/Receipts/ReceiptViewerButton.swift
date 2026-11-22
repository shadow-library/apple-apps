import Foundation
import MemoirCore
import ShadowAppShell
import ShadowDesignSystem
import SwiftUI

/// memoir-web's "View receipt" on an expense's detail, opening the receipt photo in a sheet.
struct ReceiptViewerButton: View {
  let receipt: UUID
  let subject: String
  let context: MemoirScreenContext
  @State private var isViewing = false
  @Environment(SyncRuntimes.self) private var sync: SyncRuntimes?

  var body: some View {
    Button {
      isViewing = true
    } label: {
      Label(title: { Text("View receipt", tableName: "Receipts") }, icon: { Image(systemName: "doc.text.image") })
    }
    .buttonStyle(.bordered)
    .sheet(isPresented: $isViewing) {
      let main = context.stores.main
      ReceiptViewer(model: ReceiptViewerModel(receiptID: receipt, main: main, blobs: .live(main: main, sync: sync)), subject: subject)
        .shadowSheetStyle(.full)
    }
  }

  /// memoir-web `deleteDescription`'s addition for an expense with a receipt.
  static var deletionNote: String { String(localized: "Its receipt photo is deleted too.", table: "Receipts") }
}
