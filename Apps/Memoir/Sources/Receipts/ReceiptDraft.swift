import Foundation
import MemoirCore
import Observation
import ShadowAI
import ShadowAppShell

/// The receipt of an expense being added: the photo the owner picked or scanned, kept in memory until the expense is saved, and what was read from it.
/// Nothing reaches the vault before the form saves, so a cancelled form leaves no blob behind.
@MainActor
@Observable
final class ReceiptDraft {
  enum Photo: Equatable {
    case none
    case preparing
    case ready(ReceiptPhoto)
    case failed(ReceiptPhotoError)
  }

  enum Reading: Equatable {
    case idle
    case recognizing
    case structuring
    case read(ReceiptReading)
    case failed(PresentedError)
  }

  private(set) var photo = Photo.none
  private(set) var reading = Reading.idle
  /// Set once the owner filled the form from the reading; the expense is then saved as scanned.
  private(set) var isScanUsed = false
  /// The consent the structuring call still needs; the screen asks for it and calls `read()` again once it is given.
  var consentRequest: AIConsentRequest?
  let blobs: ReceiptBlobs
  let reader: ReceiptReader?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var recognized: String?

  init(blobs: ReceiptBlobs, reader: ReceiptReader?) {
    self.blobs = blobs
    self.reader = reader
  }

  /// Reading needs the app's AI services; without them a photo is only kept.
  convenience init(context: MemoirScreenContext, sync: SyncRuntimes?, services: AIServices?) {
    let main = context.stores.main
    self.init(blobs: .live(main: main, sync: sync), reader: services.map { ReceiptReader.live(services: $0, main: main) })
  }

  var hasPhoto: Bool { photo != .none }

  /// memoir-web blocks saving while the photo uploads or is invalid; here while it is prepared or could not be used.
  var blocksSave: Bool {
    switch photo {
    case .preparing, .failed: true
    case .none, .ready: false
    }
  }

  var isReading: Bool { reading == .recognizing || reading == .structuring }

  var canRead: Bool {
    guard reader != nil, case .ready = photo else { return false }
    return !isReading
  }

  var attachment: ReceiptAttachment? {
    guard case .ready(let photo) = photo else { return nil }
    return ReceiptAttachment(photo: photo, scanned: isScanUsed)
  }

  /// Shows a pick as being prepared while its image loads, which can take a while from iCloud Photos; a later pick or a removal makes it stale.
  func startPick() -> Int {
    replace(with: .preparing)
  }

  /// Prepares the picked image; a pick started before a newer one, or before the photo was removed, is dropped.
  func take(_ data: Data, pick: Int? = nil) async {
    guard pick.map({ $0 == generation }) ?? true else { return }
    let current = pick ?? replace(with: .preparing)
    let prepared = await Self.prepare(data)
    guard current == generation else { return }
    switch prepared {
    case .success(let ready): photo = .ready(ready)
    case .failure(let error): photo = .failed(error)
    }
  }

  /// A pick that could not be read, or one too large to read at all.
  func refuse(_ error: ReceiptPhotoError, pick: Int? = nil) {
    guard pick.map({ $0 == generation }) ?? true else { return }
    _ = replace(with: .failed(error))
  }

  func remove() {
    _ = replace(with: .none)
  }

  /// Recognises the text once per photo, then asks the model; a consent still missing leaves the text recognised and waits for the owner.
  func read() async {
    guard let reader, case .ready(let ready) = photo, !isReading else { return }
    let current = generation
    consentRequest = nil
    let text: String
    if let recognized {
      text = recognized
    } else {
      reading = .recognizing
      do {
        text = try await reader.recognize(ready.data)
      } catch {
        guard current == generation else { return }
        reading = .failed(ReceiptCopy.presented(error))
        return
      }
      guard current == generation else { return }
      guard !text.isEmpty else {
        reading = .failed(ReceiptCopy.presented(.noText))
        return
      }
      recognized = text
    }
    reading = .structuring
    do {
      let read = try await ReceiptStructuring.read(text, router: await reader.router())
      guard current == generation else { return }
      reading = .read(read)
    } catch {
      guard current == generation else { return }
      if case .routing(.consentRequired(let request)) = error {
        reading = .idle
        consentRequest = request
        return
      }
      reading = .failed(ReceiptCopy.presented(error))
    }
  }

  func dismissReading() {
    guard !isReading else { return }
    reading = .idle
  }

  func scanUsed() {
    isScanUsed = true
  }

  private func replace(with photo: Photo) -> Int {
    generation += 1
    self.photo = photo
    reading = .idle
    recognized = nil
    isScanUsed = false
    consentRequest = nil
    return generation
  }

  @concurrent
  private nonisolated static func prepare(_ data: Data) async -> Result<ReceiptPhoto, ReceiptPhotoError> {
    do throws(ReceiptPhotoError) {
      return .success(try ReceiptPhoto.normalised(data))
    } catch {
      return .failure(error)
    }
  }
}
