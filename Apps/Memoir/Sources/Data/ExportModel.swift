import CoreTransferable
import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import UniformTypeIdentifiers

/// The archive as a file to save or share.
nonisolated struct ExportArchiveFile: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .zip) { SentTransferredFile($0.url) }
  }
}

/// `features/settings/export-screen.tsx`: prepare, then save or share, or clear. The archive is built on this device and nothing leaves it until the
/// owner saves or shares it.
@MainActor
@Observable
final class ExportModel {
  enum Stage: Equatable {
    case idle
    case preparing
    case ready(MemoirExportArchive)
    case failed(PresentedError)
  }

  private(set) var stage = Stage.idle
  private(set) var contents = VaultContents.Load.loading
  private(set) var saveFailure: PresentedError?
  var isSaving = false
  private var isShown = true

  private let stores: MemoirStores
  private let now: @Sendable () -> Date
  private let exports: MemoirExports
  private let appVersion: String

  init(context: MemoirScreenContext, exports: MemoirExports = .live, appVersion: String = SettingsCopy.version()) {
    stores = context.stores
    now = context.clock.now
    self.exports = exports
    self.appVersion = appVersion
  }

  func load() async {
    do {
      contents = .loaded(try await VaultContents.read(stores))
    } catch {
      contents = .failed
    }
  }

  func prepare() async {
    guard stage != .preparing else { return }
    stage = .preparing
    saveFailure = nil
    do {
      stage = .ready(try await MemoirExporter.archive(of: stores, at: now(), appVersion: appVersion, into: exports))
    } catch {
      stage = .failed(DataCopy.exportFailure(error))
    }
    if !isShown { clear() }
  }

  var file: ExportArchiveFile? {
    guard case .ready(let archive) = stage else { return nil }
    return ExportArchiveFile(url: archive.url)
  }

  func saved(_ result: Result<URL, any Error>) {
    guard case .failure(let error) = result else {
      saveFailure = nil
      return
    }
    saveFailure = DataCopy.saveFailure(error)
  }

  /// "Clear": the archive waiting here is removed; one already saved or shared stays where it went.
  func clear() {
    guard stage != .preparing else { return }
    try? exports.clear()
    stage = .idle
    saveFailure = nil
  }

  func appeared() {
    isShown = true
  }

  /// Leaving the screen removes the waiting archive, as clearing does; one still being prepared is removed when it is done.
  func disappeared() {
    isShown = false
    clear()
  }
}
