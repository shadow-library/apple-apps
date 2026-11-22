import Foundation
import MemoirCore
import ShadowCore
import ShadowSync

nonisolated enum ReceiptWriteError: Error {
  /// The image could not be kept; nothing was written.
  case blob(BlobError)
  /// The image was kept but the expense was not written, so nothing names it and the sync kernel removes it in time.
  case write(MemoirWriteError)
}

/// A receipt the owner is saving with a new expense: the kept image, and whether they used what was read from it.
nonisolated struct ReceiptAttachment: Sendable, Equatable {
  let photo: ReceiptPhoto
  let scanned: Bool
}

/// memoir-web attaches a receipt only while an expense is first saved (`expense-entry-panel.tsx:316`), as the core keeps a saved expense's receipt fixed.
nonisolated enum ReceiptWrites {
  /// Puts the image first, so the record that names it can never point at nothing, then writes the receipt record, the expense naming it and, when the
  /// owner used the scan, `receipt.scan` in one main-store write. The blob's name goes into the record verbatim, within moments of the put.
  static func create(_ expense: ExpenseRecord, attaching attachment: ReceiptAttachment?, blobs: ReceiptBlobs, writer: MemoirWriter) async throws(ReceiptWriteError)
    -> ExpenseRecord
  {
    guard let attachment else {
      do {
        return try await writer.write { issuer, transaction in try ExpenseEdits.create(expense, issuer: issuer, in: &transaction).expense }
      } catch {
        throw .write(error)
      }
    }
    let blob: BlobID
    do {
      blob = try await blobs.put(attachment.photo.data)
    } catch {
      throw .blob(error)
    }
    guard let name = BlobName(blob.description) else { throw .blob(.corrupt(blob, reason: "the blob id is not a blob name")) }
    let receipt = ReceiptRecord(id: UUID.v7(at: writer.clock.now()), blob: name, contentType: attachment.photo.contentType, byteCount: attachment.photo.data.count)
    var named = expense
    named.receipt = receipt.id
    let linked = named
    do {
      return try await writer.write { issuer, transaction in
        _ = try receipt.create(in: &transaction)
        let written = try ExpenseEdits.create(linked, source: attachment.scanned ? .ocr : .manual, issuer: issuer, in: &transaction).expense
        if attachment.scanned { try issuer.issue(.receiptScan(ReceiptScan(receiptId: receipt.id)), in: &transaction) }
        return written
      }
    } catch {
      throw .write(error)
    }
  }
}
