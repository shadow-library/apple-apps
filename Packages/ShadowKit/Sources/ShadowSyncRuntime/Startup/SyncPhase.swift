import Foundation
import ShadowSync

public enum SyncPhase: Sendable, Equatable {
  case vault(VaultStartupState)
  /// Protected data, the keychain or the location file cannot be read before the first unlock after a restart.
  case deviceLocked
  /// The attached location's account is signed out, unreachable for now, or cannot confirm which account it is.
  case accountUnavailable
  /// The signed-in account is not the one the location was attached with; nothing syncs until the user decides, so one account's data never reaches another.
  case accountChanged
  /// The attached vault is gone from its location; it is never created again without asking.
  case storageRemoved
  case appUpdateRequired
  /// No location is attached and none is attached automatically.
  case detached
  /// The saved location cannot be read, so sync stays off until the user turns it on again; unlike `detached`, the user did not ask for it.
  case settingsUnreadable
  /// The location's hint names another vault than the one attached here.
  case vaultMismatch(expected: VaultID, found: VaultID)
  /// The location holds vault files but nothing names their vault.
  case vaultUnrecognized
  /// The attached location holds a move notice: this device uploads nothing more there until it follows the move or stays.
  case vaultMoved(VaultMoveNotice)
  /// A move or a follow started on this device has not finished (`SyncMoveJournalStore`); nothing syncs until it does or is abandoned.
  case moveInProgress

  public var canSync: Bool {
    guard case .vault(let state) = self else { return false }
    return state.canWrite
  }

  /// The phase a sync call's failure puts the vault in, or nil when it does not decide one. An unreadable device marker is not mapped: it may be
  /// locked or corrupt, and `SyncStartup.evaluate()` tells the two apart.
  public init?(failure: SyncError) {
    switch failure {
    case .storage(.unauthenticated): self = .accountUnavailable
    case .appUpdateRequired: self = .appUpdateRequired
    case .keyRing(.deviceLocked): self = .deviceLocked
    default: return nil
    }
  }
}
