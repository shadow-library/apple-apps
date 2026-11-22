import Foundation
import ShadowAppShell

typealias MemoirVaultModel = VaultModel<MemoirOpenedVault>

extension VaultModel where Opened == MemoirOpenedVault {
  static func live() -> MemoirVaultModel {
    MemoirVaultModel { wallClock throws(VaultOpenError) in
      do throws(MemoirVaultOpenError) {
        return try await MemoirVaultOpener.open(
          try MemoirVaultOpener.appLocation(), appVersion: try MemoirVaultOpener.buildVersion(), clock: MemoirClock(now: wallClock))
      } catch {
        throw error.vaultOpenError
      }
    }
  }
}
