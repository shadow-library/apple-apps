import CoreGraphics
import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import ShadowSync
import Testing

@testable import Memoir

@MainActor
@Suite("ReceiptViewerModel", TestTimeLimit.standard)
struct ReceiptViewerModelTests {
  /// A receipt record naming `blob`, written as the main store holds it.
  private static func receipt(_ context: MemoirScreenContext, blob: BlobID) async throws -> UUID {
    let record = ReceiptRecord(id: UUID.v7(at: context.clock.now()), blob: BlobName(blob.description)!, contentType: "image/jpeg", byteCount: 10)
    try await context.writer.write { _, transaction in _ = try record.create(in: &transaction) }
    return record.id
  }

  @Test("should show this device's copy without fetching")
  func showsTheLocalCopy() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let id = try await Self.receipt(context, blob: try blobs.storeLocally(try ReceiptFixture.photo().data))
    let model = ReceiptViewerModel(receiptID: id, main: context.stores.main, blobs: blobs.blobs)

    await model.load()

    guard case .shown(let shown) = model.state else {
      Issue.record("the photo is shown, not \(model.state)")
      return
    }
    #expect(shown.image.width == 60 && shown.image.height == 120)
    #expect(blobs.fetches == 0)
  }

  @Test("should show the download while a photo another device took is fetched")
  func downloads() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs(holdsFetches: true)
    let id = try await Self.receipt(context, blob: try blobs.storeRemotely(try ReceiptFixture.photo().data))
    let model = ReceiptViewerModel(receiptID: id, main: context.stores.main, blobs: blobs.blobs)

    let loading = Task { await model.load() }
    try await TestClock.until("the download shows") { model.state == .downloading }
    blobs.release()
    await loading.value

    guard case .shown = model.state else {
      Issue.record("the fetched photo is shown, not \(model.state)")
      return
    }
    #expect(blobs.fetches == 1)
  }

  @Test(
    "should say what stands in the way when the photo can't be fetched",
    arguments: [
      (ReceiptFetchError.blob(.missing(BlobID.random())), ReceiptViewerModel.State.missing, false),
      (.blob(.corrupt(BlobID.random(), reason: "digest")), .corrupt, false),
      (.syncOff, .syncOff, true),
      (.syncUnavailable, .syncUnavailable, true),
      (.blob(.notAttached), .syncUnavailable, true),
      (.blob(.keyUnavailable(BlobID.random(), KeyID(UUID()))), .keyUnavailable, true),
      (.blob(.storage(.unavailable("offline"))), .failed(code: BlobError.storage(.unavailable("offline")).code), true),
    ])
  func mapsFetchFailures(error: ReceiptFetchError, state: ReceiptViewerModel.State, canRetry: Bool) async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let id = try await Self.receipt(context, blob: try blobs.storeRemotely(try ReceiptFixture.photo().data))
    blobs.failFetches(error)
    let model = ReceiptViewerModel(receiptID: id, main: context.stores.main, blobs: blobs.blobs)

    await model.load()

    #expect(model.state == state)
    #expect(model.canRetry == canRetry)
  }

  @Test("should load again after a failure once the photo can be fetched")
  func retries() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let id = try await Self.receipt(context, blob: try blobs.storeRemotely(try ReceiptFixture.photo().data))
    blobs.failFetches(.syncOff)
    let model = ReceiptViewerModel(receiptID: id, main: context.stores.main, blobs: blobs.blobs)
    await model.load()
    #expect(model.state == .syncOff)

    blobs.failFetches(nil)
    await model.load()

    guard case .shown = model.state else {
      Issue.record("the retried photo is shown, not \(model.state)")
      return
    }
  }

  @Test("should treat a stored copy that is not an image as damaged, and a receipt with no record as missing")
  func handlesBadFilesAndRecords() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let id = try await Self.receipt(context, blob: try blobs.storeLocally(Data("not an image".utf8)))

    let damaged = ReceiptViewerModel(receiptID: id, main: context.stores.main, blobs: blobs.blobs)
    await damaged.load()
    #expect(damaged.state == .corrupt)

    let absent = ReceiptViewerModel(receiptID: UUID.v7(at: context.clock.now()), main: context.stores.main, blobs: blobs.blobs)
    await absent.load()
    #expect(absent.state == .missing)
    #expect(blobs.fetches == 0)
  }

  @Test("should purge the receipt when its expense is deleted, and offer no undo")
  func deletingTheExpenseReleasesTheReceipt() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let expense = try await ReceiptWrites.create(
      ReceiptFixture.expense(context), attaching: ReceiptAttachment(photo: try ReceiptFixture.photo(), scanned: false), blobs: blobs.blobs, writer: context.writer)
    let receipt = try #require(expense.receipt)
    let detail = ExpenseDetailModel(id: expense.id, context: context)
    let running = Task { await detail.run() }
    defer { running.cancel() }
    try await TestClock.until("the expense shows") { detail.expense != nil }

    await detail.delete()

    try await TestClock.until("the deletion shows") { detail.deletion != nil }
    #expect(detail.deletion?.canUndo == false)
    let state = try await context.stores.main.read { transaction in try transaction.state(of: ReceiptRecord.ref(receipt)) }
    guard case .purged? = state else {
      Issue.record("the receipt record is purged so nothing names its blob, not \(String(describing: state))")
      return
    }
    let viewer = ReceiptViewerModel(receiptID: receipt, main: context.stores.main, blobs: blobs.blobs)
    await viewer.load()
    #expect(viewer.state == .missing)
  }
}
