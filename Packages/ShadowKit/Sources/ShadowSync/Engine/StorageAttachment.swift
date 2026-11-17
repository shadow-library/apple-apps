import Foundation
import OSLog
import ShadowCore
import ShadowStore

public enum StorageAttachment {
  private static let logger = Logger(category: "StorageAttachment")

  /// Idempotent and re-asserted on every start; clearing is eventually consistent on macOS.
  /// The vault is the backup while a provider is attached, so the device backup skips the directory. A failure is reported and never stops the attach.
  @discardableResult
  public static func attach(_ store: VaultStore) -> StoreError? {
    apply(excluded: true, to: store)
  }

  @discardableResult
  public static func detach(_ store: VaultStore) -> StoreError? {
    apply(excluded: false, to: store)
  }

  private static func apply(excluded: Bool, to store: VaultStore) -> StoreError? {
    do {
      try store.setExcludedFromBackup(excluded)
      return nil
    } catch {
      let reason = error.localizedDescription
      logger.error("Backup exclusion change failed excluded=\(excluded, privacy: .public) code=\(error.code, privacy: .public) reason=\(reason, privacy: .private)")
      return error
    }
  }
}
