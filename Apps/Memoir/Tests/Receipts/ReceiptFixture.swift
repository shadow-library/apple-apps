import CoreGraphics
import Foundation
import ImageIO
import MemoirCore
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import Memoir

/// Blobs held in a dictionary of files under a temporary folder, with scripted failures, recording what was put and fetched.
nonisolated final class FakeReceiptBlobs: Sendable {
  private struct State {
    var files: [BlobID: URL] = [:]
    var remote: Set<BlobID> = []
    var puts = 0
    var fetches = 0
    var putFailure: BlobError?
    var fetchFailure: ReceiptFetchError?
  }

  private let state = Mutex(State())
  let directory = FileManager.default.temporaryDirectory.appending(path: "ReceiptBlobs-\(UUID().uuidString)", directoryHint: .isDirectory)
  /// A held fetch waits until `release()` before answering, so a test can see the download in progress.
  private let gate = Mutex((released: false, waiting: CheckedContinuation<Void, Never>?.none))
  let holdsFetches: Bool

  init(holdsFetches: Bool = false) {
    self.holdsFetches = holdsFetches
  }

  var puts: Int { state.withLock { $0.puts } }
  var fetches: Int { state.withLock { $0.fetches } }

  func failPuts(_ error: BlobError?) { state.withLock { $0.putFailure = error } }
  func failFetches(_ error: ReceiptFetchError?) { state.withLock { $0.fetchFailure = error } }

  /// Stores `data` as a blob held only remotely, so viewing it fetches.
  func storeRemotely(_ data: Data) throws -> BlobID {
    let id = try place(data)
    _ = state.withLock { $0.remote.insert(id) }
    return id
  }

  func storeLocally(_ data: Data) throws -> BlobID {
    try place(data)
  }

  func data(of id: BlobID) -> Data? {
    state.withLock { $0.files[id] }.flatMap { try? Data(contentsOf: $0) }
  }

  func release() {
    let waiting = gate.withLock { gate in
      gate.released = true
      defer { gate.waiting = nil }
      return gate.waiting
    }
    waiting?.resume()
  }

  private func hold() async {
    await withCheckedContinuation { continuation in
      let released = gate.withLock { gate in
        if !gate.released { gate.waiting = continuation }
        return gate.released
      }
      if released { continuation.resume() }
    }
  }

  var blobs: ReceiptBlobs {
    ReceiptBlobs(
      put: { data throws(BlobError) in
        if let failure = self.state.withLock({ state -> BlobError? in
          state.puts += 1
          return state.putFailure
        }) {
          throw failure
        }
        do {
          return try self.place(data)
        } catch {
          throw .file("\(error)")
        }
      },
      local: { id throws(BlobError) in self.state.withLock { $0.remote.contains(id) ? nil : $0.files[id] } },
      fetch: { id throws(ReceiptFetchError) in
        let (failure, file) = self.state.withLock { state in
          state.fetches += 1
          return (state.fetchFailure, state.files[id])
        }
        if self.holdsFetches { await self.hold() }
        if let failure { throw failure }
        guard let file else { throw .blob(.missing(id)) }
        return file
      })
  }

  private func place(_ data: Data) throws -> BlobID {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = BlobID.random()
    let url = directory.appending(path: id.description)
    try data.write(to: url)
    state.withLock { $0.files[id] = url }
    return id
  }
}

nonisolated struct ReceiptTestCredentials: ModelCredentialSource {
  let origin: URL

  func credential(for provider: ModelProviderKind) async -> ProviderCredential? {
    ProviderCredential(origin: origin, secret: "sk-test")
  }
}

@MainActor
enum ReceiptFixture {
  nonisolated static let origin = URL(string: "https://api.example.com")!
  nonisolated static let host = "api.example.com"

  /// A white image with a dark band, `width` by `height` pixels, as PNG.
  nonisolated static func png(width: Int, height: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 3, width: width, height: height / 6))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  /// A white JPEG of `width` by `height` stored pixels, written with `properties`.
  nonisolated static func jpeg(width: Int, height: Int, properties: [CFString: Any]) -> Data {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png(width: width, height: height) as CFData, nil)!, 0, nil)!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  nonisolated static func properties(of data: Data) -> [String: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [:] }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
  }

  nonisolated static func photo() throws -> ReceiptPhoto {
    try ReceiptPhoto.normalised(png(width: 60, height: 120))
  }

  static func router(_ provider: ScriptedModelProvider, store: VaultStore) -> TaskRouter {
    TaskRouter(
      configuration: TaskRouterConfiguration(provider: .anthropic), anthropic: ProviderBinding(origin: origin, provider: provider),
      credentials: ReceiptTestCredentials(origin: origin), store: store, requestGuard: { _ in nil })
  }

  static func reader(_ provider: ScriptedModelProvider, store: VaultStore, text: String = "REMA 1000\nTOTAL 214.00\n23.08.2026") -> ReceiptReader {
    let router = router(provider, store: store)
    return ReceiptReader(recognize: { _ in text }, router: { router }, store: store)
  }

  static func grant(_ store: VaultStore) async throws {
    try await store.write { transaction in
      try AIConsent.decide(
        .granted, provider: host, dataClass: ReceiptStructuring.consent.dataClass, summary: ReceiptStructuring.consent.disclosure, atMillis: 1, in: &transaction)
    }
  }

  static func receipts(_ context: MemoirScreenContext) async throws -> [MemoirEntry<ReceiptRecord>] {
    try await context.stores.main.read { transaction in try ReceiptRecord.listing(in: transaction).entries }
  }

  static func expense(_ context: MemoirScreenContext, _ amountMinor: Int64 = 21_400) -> ExpenseRecord {
    ExpenseRecord(
      id: UUID.v7(at: context.clock.now()), amountMinor: amountMinor, currency: MoneyFixture.euro, occurredOn: TestClock.day0, category: MoneyFixture.food,
      loggedAtMillis: MemoirClock.millis(context.clock.now()))
  }
}
