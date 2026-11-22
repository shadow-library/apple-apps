import Foundation
import ShadowAppShell
import ShadowCore

/// The reference's words for export and deletion (`features/settings/export-screen.tsx`, `delete-screen.tsx`, `lib/data/account.provider.ts`), told for
/// a vault kept on the owner's devices rather than on a server.
enum DataCopy {
  static let typedConfirmation = "DELETE"

  static func area(_ area: VaultContents.Area) -> String {
    switch area {
    case .questsAndHistory: String(localized: "Quests and history", table: "Data")
    case .money: String(localized: "Money", table: "Data")
    case .journal: String(localized: "Journal", table: "Data")
    case .bodyAndHealth: String(localized: "Body and health", table: "Data")
    case .coaching: String(localized: "Coaching results", table: "Data")
    }
  }

  static func item(_ item: VaultContents.Item) -> String {
    switch item {
    case .quests: String(localized: "Quests", table: "Data")
    case .actions: String(localized: "Logged actions", table: "Data")
    case .expenses: String(localized: "Expenses", table: "Data")
    case .subscriptions: String(localized: "Subscriptions", table: "Data")
    case .receipts: String(localized: "Receipts", table: "Data")
    case .journalEntries: String(localized: "Entries", table: "Data")
    case .weights: String(localized: "Weights", table: "Data")
    case .meals: String(localized: "Meals", table: "Data")
    case .sideQuests: String(localized: "Side quests", table: "Data")
    case .metricDays: String(localized: "Metric days", table: "Data")
    case .coachingResults: String(localized: "Results", table: "Data")
    }
  }

  static func acknowledgement(_ acknowledgement: DeleteVaultModel.Acknowledgement) -> String {
    switch acknowledgement {
    case .permanent:
      String(
        localized: "I understand my quests, my history, my records and my experience are erased from this device permanently and cannot be restored from it.",
        table: "Data")
    case .exported: String(localized: "I have exported anything I want to keep, or I do not want to keep any of it.", table: "Data")
    }
  }

  static var terms: String {
    String(
      localized:
        "Deleting starts the moment you confirm, and it cannot be stopped or undone. It erases everything Memoir keeps on this device and turns sync off; what sync already sent stays at its location and on your other devices.",
      table: "Data")
  }

  static func deletionFailure(_ error: VaultDeletionError) -> PresentedError {
    let headline =
      switch error {
      case .notOpen: String(localized: "Your data isn’t open on this device yet, so nothing was erased.", table: "Data")
      case .syncNotStopped:
        String(localized: "Memoir couldn’t turn sync off, so nothing was erased. Try again, or turn sync off in Sync Settings first.", table: "Data")
      case .locationUnavailable, .eraseFailed: String(localized: "Something went wrong on this device. Nothing was erased.", table: "Data")
      }
    return PresentedError(headline: headline, detail: error.code)
  }

  static func exportFailure(_ error: MemoirExportError) -> PresentedError {
    PresentedError(
      headline: String(localized: "The archive could not be assembled. Nothing was deleted or changed, and retrying is safe.", table: "Data"), detail: error.code)
  }

  static func saveFailure(_ error: any Error) -> PresentedError {
    PresentedError(headline: String(localized: "The archive couldn’t be saved.", table: "Data"), detail: (error as? any ShadowError)?.code)
  }
}
