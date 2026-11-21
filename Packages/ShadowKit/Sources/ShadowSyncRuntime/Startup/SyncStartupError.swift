import Foundation
import ShadowCore
import ShadowSync

public enum SyncStartupError: ShadowError, Equatable {
  case deviceLocked
  case noStorageAccount
  case accountUnavailable
  case alreadyAttached
  case location(SyncLocationError)
  case setup(VaultSetupError)
  case storage(StorageError)
  case keyRing(KeyRingError)
  case marker(String)
  /// A move needs an attached vault.
  case notAttached
  /// The attached vault is in a phase that hands out nothing to sync with.
  case unavailable(SyncPhase)

  public var code: String {
    switch self {
    case .deviceLocked: "sync-startup.device-locked"
    case .noStorageAccount: "sync-startup.no-storage-account"
    case .accountUnavailable: "sync-startup.account-unavailable"
    case .alreadyAttached: "sync-startup.already-attached"
    case .location(let error): error.code
    case .setup(let error): error.code
    case .storage(let error): error.code
    case .keyRing(let error): error.code
    case .marker: "sync-startup.marker"
    case .notAttached: "sync-startup.not-attached"
    case .unavailable: "sync-startup.unavailable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .deviceLocked: "Sync cannot start until the device has been unlocked."
    case .noStorageAccount: "No account is signed in for this storage."
    case .accountUnavailable: "The storage account cannot be reached right now."
    case .alreadyAttached: "This vault already syncs with a location; disconnect it first."
    case .location(let error): error.errorDescription
    case .setup(let error): error.errorDescription
    case .storage(let error): error.errorDescription
    case .keyRing(let error): error.errorDescription
    case .marker(let reason): "This device's sync marker could not be read or cleared (\(reason))."
    case .notAttached: "No vault syncs with a location on this device."
    case .unavailable: "The attached vault cannot sync right now."
    }
  }
}
