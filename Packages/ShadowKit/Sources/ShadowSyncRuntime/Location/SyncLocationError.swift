import Foundation
import ShadowCore

public enum SyncLocationError: ShadowError, Equatable {
  case insideVaultDirectory(String)
  /// The file system refused access; before the first unlock this is data protection, after it a real permission problem.
  case permissionDenied(String)
  case unreadable(String)
  case unwritable(String)

  public var code: String {
    switch self {
    case .insideVaultDirectory: "sync-location.inside-vault-directory"
    case .permissionDenied: "sync-location.permission-denied"
    case .unreadable: "sync-location.unreadable"
    case .unwritable: "sync-location.unwritable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .insideVaultDirectory(let path): "The sync location file \(path) would sit inside a vault directory, which holds only the vault's own files."
    case .permissionDenied(let reason): "The sync location may not be read or written (\(reason))."
    case .unreadable(let reason): "The sync location could not be read (\(reason))."
    case .unwritable(let reason): "The sync location could not be saved (\(reason))."
    }
  }
}
