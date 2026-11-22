import CoreGraphics
import Foundation
import ImageIO
import MemoirCore
import ShadowCore
import ShadowDesignSystem
import ShadowSync
import SwiftUI
import UniformTypeIdentifiers

/// In-memory stores and a drawn receipt for the receipt screens' previews; an in-memory store keeps no blobs, so the image comes from a temporary file.
private enum ReceiptPreviewData {
  static func receiptImage() -> Data {
    let (width, height) = (360, 720)
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return Data() }
    context.setFillColor(gray: 0.97, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 0.2, alpha: 1)
    for line in 0..<18 { context.fill(CGRect(x: 32, y: 60 + line * 34, width: line % 3 == 0 ? 296 : 180, height: 12)) }
    let output = NSMutableData()
    guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return Data() }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  static func viewer(failing failure: ReceiptFetchError? = nil) async throws -> ReceiptViewerModel {
    let context = try MemoirScreenContext.inMemory()
    let photo = try ReceiptPhoto.normalised(receiptImage())
    let file = FileManager.default.temporaryDirectory.appending(path: "receipt-preview-\(UUID().uuidString).jpg")
    try photo.data.write(to: file)
    let blob = BlobID.random()
    guard let name = BlobName(blob.description) else { throw BlobError.corrupt(blob, reason: "preview") }
    let receipt = ReceiptRecord(id: UUID.v7(at: context.clock.now()), blob: name, contentType: photo.contentType, byteCount: photo.data.count)
    try await context.writer.write { _, transaction in _ = try receipt.create(in: &transaction) }
    let blobs = ReceiptBlobs(
      put: { _ throws(BlobError) in throw .noDirectory }, local: { _ throws(BlobError) in failure == nil ? file : nil },
      fetch: { _ throws(ReceiptFetchError) in
        if let failure { throw failure }
        return file
      })
    return ReceiptViewerModel(receiptID: receipt.id, main: context.stores.main, blobs: blobs)
  }

  @MainActor
  static func form() async throws -> ExpenseForm {
    let context = try MemoirScreenContext.inMemory()
    let draft = ReceiptDraft(
      blobs: ReceiptBlobs(
        put: { _ throws(BlobError) in throw .noDirectory }, local: { _ throws(BlobError) in nil }, fetch: { _ throws(ReceiptFetchError) in throw .syncOff }),
      reader: nil)
    await draft.take(receiptImage())
    return ExpenseForm(mode: .create, options: try await MoneyOptions.load(context), context: context, locale: .current, receipt: draft)
  }
}

private struct ReceiptViewerPreview: View {
  let failure: ReceiptFetchError?
  @State private var model: ReceiptViewerModel?

  var body: some View {
    Group {
      if let model { ReceiptViewer(model: model, subject: "Groceries · 2 March 2026") } else { ProgressView() }
    }
    .task { model = try? await ReceiptPreviewData.viewer(failing: failure) }
    .shadowTheme()
  }
}

private struct ReceiptFormPreview: View {
  @State private var form: ExpenseForm?

  var body: some View {
    NavigationStack {
      Form {
        if let form { ReceiptFormSection(form: form) }
      }
      .formStyle(.grouped)
    }
    .task { form = try? await ReceiptPreviewData.form() }
    .shadowTheme()
  }
}

#Preview("Receipt photo") { ReceiptViewerPreview(failure: nil) }

#Preview("Sync off") { ReceiptViewerPreview(failure: .syncOff) }

#Preview("Sync can't run") { ReceiptViewerPreview(failure: .syncUnavailable) }

#Preview("Missing") { ReceiptViewerPreview(failure: .blob(.missing(BlobID.random()))) }

#Preview("Form with a photo") { ReceiptFormPreview() }
