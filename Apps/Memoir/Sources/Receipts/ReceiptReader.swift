import Foundation
import ShadowAI
import ShadowAppShell
import ShadowStore
import Vision

/// How a receipt is read: its text recognised on this device, then structured through the vault's model router under the receipt-text consent.
nonisolated struct ReceiptReader: Sendable {
  let recognize: @Sendable (Data) async throws(ReceiptReadFailure) -> String
  let router: @Sendable () async -> TaskRouter
  /// The store the router keeps its consents and ledger in, where a consent asked for is granted.
  let store: VaultStore

  @MainActor
  static func live(services: AIServices, main: VaultStore) -> ReceiptReader {
    ReceiptReader(
      recognize: { data throws(ReceiptReadFailure) in try await ReceiptText.recognize(data) }, router: { await services.router(store: main) }, store: main)
  }
}

nonisolated enum ReceiptText {
  /// The document's lines top to bottom, as a receipt reads; plain text recognition when no document is found.
  @concurrent
  static func recognize(_ image: Data) async throws(ReceiptReadFailure) -> String {
    do {
      let documents = try await RecognizeDocumentsRequest().perform(on: image)
      let lines = documents.flatMap { $0.document.text.lines.map(\.transcript) }
      if !lines.isEmpty { return text(lines) }
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      return text(try await request.perform(on: image).compactMap { $0.topCandidates(1).first?.string })
    } catch {
      throw .recognition
    }
  }

  private static func text(_ lines: [String]) -> String {
    lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
  }
}
