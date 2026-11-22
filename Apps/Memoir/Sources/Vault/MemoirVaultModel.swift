import Foundation
import OSLog
import Observation
import ShadowCore
import ShadowStore

@MainActor
@Observable
final class MemoirVaultModel {
  enum State {
    case opening
    case ready(MemoirOpenedVault)
    case failed(MemoirVaultOpenError)
  }

  typealias Opener = @Sendable () async throws(MemoirVaultOpenError) -> MemoirOpenedVault

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.memoir", category: "vault")

  private(set) var state = State.opening
  private let opener: Opener
  @ObservationIgnored private var opening: Task<Void, Never>?

  init(opener: @escaping Opener) {
    self.opener = opener
  }

  var vault: MemoirOpenedVault? {
    guard case .ready(let vault) = state else { return nil }
    return vault
  }

  var failure: MemoirVaultOpenError? {
    guard case .failed(let error) = state else { return nil }
    return error
  }

  /// A second call while the vault opens waits for the first; an open vault is kept.
  func open() async {
    if let opening { return await opening.value }
    guard vault == nil else { return }
    let task = Task {
      state = .opening
      do throws(MemoirVaultOpenError) {
        state = .ready(try await opener())
      } catch {
        Self.logger.error("The vault did not open code=\(error.code, privacy: .public)")
        state = .failed(error)
      }
      opening = nil
    }
    opening = task
    await task.value
  }

  /// Walks the derived rows to the device's current day, after midnight, a time zone change or a return to the foreground.
  func refreshDay() async {
    guard let vault else { return }
    do {
      try await vault.refreshDay()
    } catch {
      Self.logger.error("The day did not refresh code=\(error.code, privacy: .public)")
    }
  }
}

extension MemoirVaultModel {
  static func live() -> MemoirVaultModel {
    MemoirVaultModel { () throws(MemoirVaultOpenError) -> MemoirOpenedVault in
      try await MemoirVaultOpener.open(try MemoirVaultOpener.appLocation(), appVersion: try MemoirVaultOpener.buildVersion())
    }
  }
}
