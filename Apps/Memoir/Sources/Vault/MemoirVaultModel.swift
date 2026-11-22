import Foundation
import OSLog
import ShadowAppShell
import ShadowStore

typealias MemoirVaultModel = VaultModel<MemoirOpenedVault>

extension VaultModel where Opened == MemoirOpenedVault {
  nonisolated private static var logger: Logger { Logger(subsystem: AppIdentity.memoir.id, category: "vault") }

  static func live() -> MemoirVaultModel {
    MemoirVaultModel { wallClock throws(VaultOpenError) in
      do throws(MemoirVaultOpenError) {
        return try await MemoirVaultOpener.open(try MemoirVaultOpener.appLocation(), appVersion: try MemoirVaultOpener.buildVersion(), wallClock: wallClock)
      } catch {
        throw error.vaultOpenError
      }
    }
  }

  /// Walks the derived rows to the device's current day, after midnight, a time zone change or a return to the foreground.
  func refreshDay() async {
    guard let opened else { return }
    do {
      try await opened.refreshDay()
    } catch {
      Self.logger.error("The day did not refresh code=\(error.code, privacy: .public)")
    }
  }
}
