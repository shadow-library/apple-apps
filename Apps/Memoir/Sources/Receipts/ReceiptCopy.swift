import Foundation
import ShadowAppShell
import ShadowSync

/// The receipt screens' words for what went wrong, with memoir-web's copy where it has some (`lib/apis/receipt-upload.ts`, `receipt-download.ts`,
/// `lib/data/command-errors.ts`).
enum ReceiptCopy {
  static func photoIssue(_ error: ReceiptPhotoError) -> String {
    switch error {
    case .unreadable: String(localized: "That file isn’t a photo Memoir can keep. Use a JPEG, PNG, HEIC or other image.", table: "Receipts")
    case .tooLarge: String(localized: "That photo is too large to keep. Pick a smaller one.", table: "Receipts")
    }
  }

  static func presented(_ failure: ReceiptReadFailure) -> PresentedError {
    switch failure {
    case .noText: PresentedError(headline: String(localized: "No text was found on this photo, so nothing was sent.", table: "Receipts"), detail: nil)
    case .recognition: PresentedError(headline: String(localized: "This device couldn’t read the photo’s text, so nothing was sent.", table: "Receipts"), detail: nil)
    case .routing(let error): AIErrors.presented(error, app: .memoir)
    case .model(let error): AIErrors.presented(error, app: .memoir)
    case .unusable: PresentedError(headline: String(localized: "Receipt scanning isn’t available right now.", table: "Receipts"), detail: "OCR_002")
    }
  }

  static func presented(_ error: ReceiptWriteError) -> PresentedError? {
    switch error {
    case .blob(let blob):
      PresentedError(headline: String(localized: "The receipt photo couldn’t be kept. Try again, or remove it to save without one.", table: "Receipts"), detail: blob.code)
    case .write(let write): WritingErrors.presented(write)
    }
  }
}
