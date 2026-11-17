import Foundation

enum DraftImportErrors {
  static func presented(_ error: any Error) -> PresentedError {
    guard let error = error as? DraftFileError else { return ReaderErrors.presented(error) }
    return PresentedError(headline: headline(for: error), detail: nil)
  }

  private static func headline(for error: DraftFileError) -> String {
    switch error {
    case .unreadable: String(localized: "That file could not be opened.", table: "Reader")
    case .notText: String(localized: "That file is not a text file. Choose a plain text or Markdown file.", table: "Reader")
    case .unsupportedEncoding: String(localized: "That file is not saved as UTF-8 text. Save it as UTF-8 from your editor and try again.", table: "Reader")
    case .empty: String(localized: "That file has no text in it.", table: "Reader")
    case .tooLarge: String(localized: "That file is too large to import as a chapter.", table: "Reader")
    }
  }
}
