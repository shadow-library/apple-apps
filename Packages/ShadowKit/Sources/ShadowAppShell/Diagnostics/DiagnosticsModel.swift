import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers

/// The archive as a file to save or share.
nonisolated struct DiagnosticsFile: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .zip) { SentTransferredFile($0.url) }
  }
}

/// Prepare, then save or share, or clear. The archive is built on this device and nothing leaves it until the owner saves or shares it; the copy
/// waiting here is removed on Clear, when the screen goes away (once a preparation in flight is done) and at the next launch.
@Observable
final class DiagnosticsModel {
  enum Stage: Equatable {
    case idle
    case preparing
    case ready(DiagnosticsArchive)
    case failed(PresentedError)
  }

  private(set) var stage = Stage.idle
  private(set) var saveFailure: PresentedError?
  var isSaving = false
  private var isShown = true
  private let builder: DiagnosticsBuilder

  init(builder: DiagnosticsBuilder) {
    self.builder = builder
  }

  func prepare() async {
    guard stage != .preparing else { return }
    stage = .preparing
    saveFailure = nil
    do throws(DiagnosticsError) {
      stage = .ready(try await builder.build())
    } catch {
      stage = .failed(PresentedError(error))
    }
    if !isShown { clear() }
  }

  var file: DiagnosticsFile? {
    guard case .ready(let archive) = stage else { return nil }
    return DiagnosticsFile(url: archive.url)
  }

  func saved(_ result: Result<URL, any Error>) {
    guard case .failure(let error) = result else {
      saveFailure = nil
      return
    }
    saveFailure = PresentedError(error)
  }

  func clear() {
    guard stage != .preparing else { return }
    try? builder.archives.clear()
    stage = .idle
    saveFailure = nil
  }

  func appeared() {
    isShown = true
  }

  func disappeared() {
    isShown = false
    clear()
  }
}
