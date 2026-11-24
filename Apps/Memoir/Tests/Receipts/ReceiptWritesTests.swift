import Foundation
import MemoirCore
import ShadowAppShell
import ShadowStore
import ShadowSync
import Testing

@testable import Memoir

@MainActor
@Suite("ReceiptWrites", TestTimeLimit.standard)
struct ReceiptWritesTests {
  @Test("should put the image first, then write the receipt naming it, the expense linking it and the scan in one write")
  func attachesInOrder() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let photo = try ReceiptFixture.photo()
    let expense = ReceiptFixture.expense(context)

    let written = try await ReceiptWrites.create(
      expense, attaching: ReceiptAttachment(photo: photo, scanned: true), blobs: blobs.blobs, writer: context.writer)

    #expect(blobs.puts == 1)
    let receipt = try #require(try await ReceiptFixture.receipts(context).first?.record)
    let blob = try #require(BlobID(receipt.blob.description))
    #expect(blobs.data(of: blob) == photo.data, "the record names the blob that holds the image, verbatim")
    #expect(receipt.contentType == "image/jpeg")
    #expect(receipt.byteCount == photo.data.count)
    #expect(written.receipt == receipt.id)
    #expect(try await MoneyFixture.expenseEntries(context).map(\.record.receipt) == [receipt.id])
    let creation = ExpenseCreation(id: expense.id, source: .ocr, occurredOn: expense.occurredOn)
    #expect(try await MoneyFixture.bodies(context) == [.expenseCreate(creation), .receiptScan(ReceiptScan(receiptId: receipt.id))])
  }

  @Test("should save a kept but unread photo as a typed expense with no scan")
  func attachesWithoutScan() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    let expense = ReceiptFixture.expense(context)

    _ = try await ReceiptWrites.create(expense, attaching: ReceiptAttachment(photo: try ReceiptFixture.photo(), scanned: false), blobs: blobs.blobs, writer: context.writer)

    #expect(try await ReceiptFixture.receipts(context).count == 1)
    #expect(try await MoneyFixture.bodies(context) == [.expenseCreate(ExpenseCreation(id: expense.id, source: .manual, occurredOn: expense.occurredOn))])
  }

  @Test("should write nothing when the image cannot be kept")
  func writesNothingWithoutTheBlob() async throws {
    let context = try await MoneyFixture.context()
    let blobs = FakeReceiptBlobs()
    blobs.failPuts(.file("disk full"))

    await #expect(throws: ReceiptWriteError.self) {
      try await ReceiptWrites.create(
        ReceiptFixture.expense(context), attaching: ReceiptAttachment(photo: try ReceiptFixture.photo(), scanned: true), blobs: blobs.blobs, writer: context.writer)
    }

    #expect(try await ReceiptFixture.receipts(context).isEmpty)
    #expect(try await MoneyFixture.expenseEntries(context).isEmpty)
    #expect(try await MoneyFixture.bodies(context).isEmpty)
  }

  @Test("should leave no receipt record when the expense write fails after the image was kept")
  func rollsBackTheRecordWithTheExpense() async throws {
    let context = try await MoneyFixture.context()
    let existing = try await MoneyFixture.expense(context, 500)
    let blobs = FakeReceiptBlobs()
    let refused = ExpenseRecord(
      id: existing.id, amountMinor: 900, currency: MoneyFixture.euro, occurredOn: TestClock.day0, category: MoneyFixture.food, loggedAtMillis: existing.loggedAtMillis)

    let attachment = ReceiptAttachment(photo: try ReceiptFixture.photo(), scanned: true)
    do throws(ReceiptWriteError) {
      _ = try await ReceiptWrites.create(refused, attaching: attachment, blobs: blobs.blobs, writer: context.writer)
      Issue.record("an expense id already in use is refused")
    } catch {
      guard case .write = error else {
        Issue.record("the write failed, not the blob: \(error)")
        return
      }
    }

    #expect(blobs.puts == 1, "the image was kept first; nothing names it, so the sync kernel removes it in time")
    #expect(try await ReceiptFixture.receipts(context).isEmpty, "no record names the kept image")
    #expect(try await MoneyFixture.expenseEntries(context).map(\.record.receipt) == [nil])
    #expect(try await MoneyFixture.bodies(context) == [.expenseCreate(ExpenseCreation(id: existing.id, occurredOn: existing.occurredOn))])
  }

  @Test("should keep the image in the main store's blobs and show it from this device's copy")
  func keepsTheImageInTheVault() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "ReceiptVault-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = TestClock(day: 0, minute: 720).memoir(deviceZone: TestClock.utc)
    let projection = try MemoirReconciler(appVersion: "test", now: clock.now, deviceZone: clock.deviceZone)
    let stores = try MemoirStores.open(in: try MemoirVault(directory: directory), wallClock: clock.now, projection: projection)
    let context = MemoirScreenContext(stores: stores, clock: clock)
    try await context.writer.write { _, transaction in
      _ = try AccountSettingsRecord(defaultCurrency: MoneyFixture.euro, enabledCurrencies: [MoneyFixture.euro]).create(in: &transaction)
    }
    let blobs = ReceiptBlobs.live(main: stores.main, sync: nil)
    let photo = try ReceiptFixture.photo()

    _ = try await ReceiptWrites.create(
      ReceiptFixture.expense(context), attaching: ReceiptAttachment(photo: photo, scanned: false), blobs: blobs, writer: context.writer)

    let receipt = try #require(try await ReceiptFixture.receipts(context).first?.record)
    let blob = try #require(BlobID(receipt.blob.description))
    #expect(try await VaultBlobs(store: stores.main).status(of: blob) == .waitingToUpload, "the image waits for sync's next upload")
    let viewer = ReceiptViewerModel(receiptID: receipt.id, main: stores.main, blobs: blobs)
    await viewer.load()
    guard case .shown(let shown) = viewer.state else {
      Issue.record("this device's copy is shown without sync, not \(viewer.state)")
      return
    }
    #expect(try Data(contentsOf: shown.file) == photo.data)
  }
}
