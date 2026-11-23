import Foundation
import MemoirCore
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

  static func store(_ store: MemoirStoreKind) -> String {
    switch store {
    case .main: String(localized: "Everyday records", table: "Data")
    case .activity: String(localized: "Activity records", table: "Data")
    case .restricted: String(localized: "Health records", table: "Data")
    }
  }

  static func importFailure(_ error: MemoirImportError) -> PresentedError {
    let headline =
      switch error {
      case .unreadable: String(localized: "This file couldn’t be opened as a zip archive. Nothing was restored.", table: "Data")
      case .notAnExport: String(localized: "This archive isn’t a Memoir export. Nothing was restored.", table: "Data")
      case .newerVersion, .newerRecords:
        String(localized: "This export was made by a newer version of Memoir. Update Memoir on this device, then restore it. Nothing was restored.", table: "Data")
      case .malformed: String(localized: "This export is damaged or was changed after it was made, so nothing was restored.", table: "Data")
      case .tooLarge: String(localized: "This archive is larger than a restore can take. Nothing was restored.", table: "Data")
      case .receipt: String(localized: "A receipt image in this export is missing or damaged, so nothing was restored.", table: "Data")
      case .file: String(localized: "Something went wrong on this device. Nothing was restored.", table: "Data")
      case .syncUnsettled:
        String(
          localized: "Sync hasn’t settled, so nothing was restored. Wait until sync is up to date, or turn it off, then try again.", table: "Data")
      }
    return PresentedError(headline: headline, detail: error.code)
  }

  static func restoreFailure(_ error: MemoirRestoreError) -> PresentedError {
    let headline =
      switch error {
      case .vaultNotEmpty:
        String(localized: "Memoir already holds data on this device, so nothing was restored. A restore only goes into an empty vault.", table: "Data")
      case .unfinished:
        String(localized: "The restore stopped partway, so part of the export is on this device. Erase it, then restore again.", table: "Data")
      default: String(localized: "The restore didn’t finish, and nothing was kept. Try again.", table: "Data")
      }
    return PresentedError(headline: headline, detail: error.code)
  }

  static func saveFailure(_ error: any Error) -> PresentedError {
    PresentedError(headline: String(localized: "The archive couldn’t be saved.", table: "Data"), detail: (error as? any ShadowError)?.code)
  }
}
