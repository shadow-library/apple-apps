import Foundation
import NovelForgeCore
import ShadowCore

enum ExportErrors {
  static func presented(_ error: ExportError) -> PresentedError {
    if case .store(let store) = error { return PresentedError(store) }
    return PresentedError(headline: headline(code: error.code) ?? generic, detail: error.code)
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:EXP_001
  static func headline(code: String) -> String? {
    switch code {
    case "PRJ_001": String(localized: "This novel isn't there any more.", table: "Export")
    case "EXP_001": String(localized: "There is nothing to export yet. Write or import a chapter first.", table: "Export")
    case "export.unreadable_chapters": String(localized: "Some final chapters are stored in a form this version can't read, so the export would leave them out.", table: "Export")
    case "export.archive_too_many_entries": String(localized: "This novel has too many chapters for one package.", table: "Export")
    case "export.archive_entry_too_large", "export.archive_too_large": String(localized: "This novel is too large for one package.", table: "Export")
    case "export.archive_name_invalid", "export.archive_duplicate_name": String(localized: "The package couldn't be named. Rename the novel and try again.", table: "Export")
    default: nil
    }
  }

  static var generic: String { String(localized: "Something went wrong.", table: "Export") }
}
