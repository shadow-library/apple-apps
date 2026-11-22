import CoreGraphics
import Foundation
import MemoirCore
import Observation
import ShadowStore
import ShadowSync

/// The image as it is shown, with the file it came from for sharing.
nonisolated struct ReceiptShown: Sendable, Equatable {
  let file: URL
  let image: CGImage
  let contentType: String

  static func == (lhs: ReceiptShown, rhs: ReceiptShown) -> Bool {
    lhs.file == rhs.file && lhs.contentType == rhs.contentType && lhs.image === rhs.image
  }
}

/// memoir-web `ReceiptViewer`: the receipt's image, from this device's copy or fetched through sync, with what stands in the way when it can't be shown.
@MainActor
@Observable
final class ReceiptViewerModel {
  /// The longest side the viewer decodes, enough to zoom into a receipt's small print.
  nonisolated static let displaySide = 4096

  enum State: Equatable {
    case loading
    case downloading
    case shown(ReceiptShown)
    /// No receipt record, or no stored copy: deleted on another device, or its upload never finished.
    case missing
    /// The record was written by a newer version of Memoir.
    case unreadable
    case corrupt
    /// This device does not hold the image and sync is off here.
    case syncOff
    /// This device does not hold the image and sync is set up but cannot run now.
    case syncUnavailable
    case keyUnavailable
    /// Anything else, such as storage that could not be reached; worth trying again.
    case failed(code: String?)
  }

  let receiptID: UUID
  private(set) var state = State.loading
  @ObservationIgnored private let main: VaultStore
  @ObservationIgnored private let blobs: ReceiptBlobs
  @ObservationIgnored private var attempt = 0

  init(receiptID: UUID, main: VaultStore, blobs: ReceiptBlobs) {
    self.receiptID = receiptID
    self.main = main
    self.blobs = blobs
  }

  var canRetry: Bool {
    switch state {
    case .failed, .syncOff, .syncUnavailable, .keyUnavailable: true
    case .loading, .downloading, .shown, .missing, .unreadable, .corrupt: false
    }
  }

  func load() async {
    attempt += 1
    let current = attempt
    state = .loading
    let next = await resolve {
      if current == attempt { state = .downloading }
    }
    guard current == attempt else { return }
    state = next
  }

  private func resolve(downloading: () -> Void) async -> State {
    let id = receiptID
    let reading: MemoirReading<MemoirEntry<ReceiptRecord>>
    do {
      reading = try await main.read { transaction in try ReceiptRecord.read(id: id, in: transaction) }
    } catch {
      return .failed(code: error.code)
    }
    let record: ReceiptRecord
    switch reading {
    case .readable(let entry) where !entry.isRemoved: record = entry.record
    case .readable, .absent: return .missing
    case .unreadable: return .unreadable
    }
    guard let blob = BlobID(record.blob.description) else { return .corrupt }
    let file: URL
    do throws(ReceiptFetchError) {
      if let local = try await held(blob) {
        file = local
      } else {
        downloading()
        file = try await blobs.fetch(blob)
      }
    } catch {
      return Self.state(for: error)
    }
    guard let image = await Self.decode(file) else { return .corrupt }
    return .shown(ReceiptShown(file: file, image: image, contentType: record.contentType))
  }

  private func held(_ blob: BlobID) async throws(ReceiptFetchError) -> URL? {
    do throws(BlobError) {
      return try await blobs.local(blob)
    } catch {
      throw .blob(error)
    }
  }

  private static func state(for error: ReceiptFetchError) -> State {
    switch error {
    case .syncOff: .syncOff
    case .syncUnavailable, .blob(.notAttached): .syncUnavailable
    case .blob(.missing): .missing
    case .blob(.corrupt): .corrupt
    case .blob(.keyUnavailable): .keyUnavailable
    case .blob(let other): .failed(code: other.code)
    }
  }

  @concurrent
  private nonisolated static func decode(_ file: URL) async -> CGImage? {
    ReceiptImages.decode(contentsOf: file, longestSide: displaySide)
  }
}
