import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import ShadowSyncRuntime

/// The words for a failure of a settings action: a headline for the user and the error's code for support. `kind` is the storage the action talked to.
enum SyncSettingsErrors {
  static func presented(_ error: any Error, kind: SyncProviderKind?) -> PresentedError {
    PresentedError(headline: isKeychainRefusal(error) ? teamlessHeadline : headline(for: error, kind: kind), detail: code(of: error))
  }

  static var teamlessHeadline: String {
    String(localized: "This build of Novel Forge cannot use the keychain on this device, so it cannot sync.", table: "SyncSettings")
  }

  /// The keychain refuses a build without an application identifier (a Mac build signed without a team), whichever layer reports it.
  static func isKeychainRefusal(_ error: any Error) -> Bool {
    switch error {
    case let error as SecureStoreError: error.isMissingEntitlement
    case let error as KeyRingError: error == .keychainUnavailable
    case let error as SyncCredentialError: error == .keychainUnavailable
    case let error as VaultSetupError: error == .keyRing(.keychainUnavailable)
    case let error as SyncStartupError:
      switch error {
      case .keychainUnavailable, .keyRing(.keychainUnavailable), .setup(.keyRing(.keychainUnavailable)), .unavailable(.keychainUnavailable): true
      default: false
      }
    case let error as SyncMoveError:
      switch error {
      case .startup(let startup): isKeychainRefusal(startup)
      case .sync(.keyRing(.keychainUnavailable)): true
      default: false
      }
    default: false
    }
  }

  private static func code(of error: any Error) -> String? {
    (error as? any ShadowError)?.code
  }

  private static func headline(for error: any Error, kind: SyncProviderKind?) -> String {
    switch error {
    case let error as SyncStartupError: headline(for: error, kind: kind)
    case let error as VaultSetupError: headline(for: error, kind: kind)
    case let error as SyncMoveError: headline(for: error, kind: kind)
    case let error as StorageError: headline(for: error, kind: kind)
    case let error as SyncCredentialError: headline(for: error)
    case is SecureStoreError, is KeyRingError: keychainHeadline
    case is SyncLocationError: locationHeadline
    default: String(localized: "Something went wrong.", table: "SyncSettings")
    }
  }

  private static func headline(for error: SyncStartupError, kind: SyncProviderKind?) -> String {
    switch error {
    case .deviceLocked: lockedHeadline
    case .keychainUnavailable: teamlessHeadline
    case .noStorageAccount where kind == .iCloud: String(localized: "Sign in to iCloud on this device first.", table: "SyncSettings")
    case .noStorageAccount: String(localized: "No account is signed in for this storage.", table: "SyncSettings")
    case .accountUnavailable: String(localized: "The storage account cannot be reached right now. Try again later.", table: "SyncSettings")
    case .alreadyAttached: String(localized: "Sync was turned on meanwhile, perhaps in another window.", table: "SyncSettings")
    case .notAttached: String(localized: "Sync was turned off meanwhile, perhaps in another window.", table: "SyncSettings")
    case .location: locationHeadline
    case .setup(let setup): headline(for: setup, kind: kind)
    case .storage(let storage): headline(for: storage, kind: kind)
    case .keyRing, .marker: keychainHeadline
    case .unavailable: String(localized: "Sync cannot run right now. Resolve the problem shown above first.", table: "SyncSettings")
    }
  }

  private static func headline(for error: VaultSetupError, kind: SyncProviderKind?) -> String {
    switch error {
    case .storage(let storage): headline(for: storage, kind: kind)
    case .keyRing: keychainHeadline
    case .deviceLocked: lockedHeadline
    case .vaultMismatch: String(localized: "This location now holds a different library. Look at it again before joining.", table: "SyncSettings")
    case .vaultNotFound: String(localized: "The library is no longer at this location. Look at it again.", table: "SyncSettings")
    case .newerFormat: newerFormatHeadline
    case .unrecognized: unrecognizedHeadline
    case .cancelled: String(localized: "Setting up sync was cancelled before anything was written.", table: "SyncSettings")
    }
  }

  private static func headline(for error: SyncMoveError, kind: SyncProviderKind?) -> String {
    switch error {
    case .sameLocation: String(localized: "Your library already syncs here. Choose another location.", table: "SyncSettings")
    case .vaultMismatch: String(localized: "That move is for another library.", table: "SyncSettings")
    case .targetHoldsVault: String(localized: "That location already holds a synced library. A library moves only into an empty location.", table: "SyncSettings")
    case .targetMissingVault:
      String(localized: "Your library is not at that location yet. Check that it is where your other device moved it, or try again later.", table: "SyncSettings")
    case .targetKindMismatch: String(localized: "Your library moved to another kind of storage.", table: "SyncSettings")
    case .blobTooLarge: String(localized: "A file in your library is too large for that storage.", table: "SyncSettings")
    case .alreadyMoved: String(localized: "Another device has already moved your library. Follow it instead.", table: "SyncSettings")
    case .noticeUnreadable: String(localized: "A move notice is there, but this device cannot open it yet; its key may still be on its way.", table: "SyncSettings")
    case .moveInProgress: String(localized: "Another move is still in progress on this device. Finish or abandon it first.", table: "SyncSettings")
    case .verificationFailed: String(localized: "What was copied did not read back correctly. Your library still syncs where it did; try again.", table: "SyncSettings")
    case .sourceNotSettled: String(localized: "This device's latest changes could not be sent first. Try again once sync is up to date.", table: "SyncSettings")
    case .source(let storage): headline(for: storage, kind: nil)
    case .target(let storage): headline(for: storage, kind: kind)
    case .sync(.awaitingKey): String(localized: "This device does not have your library's key yet.", table: "SyncSettings")
    case .sync(.keyRing(.deviceLocked)): lockedHeadline
    case .sync(.keyRing): keychainHeadline
    case .sync(.storage(let storage)): headline(for: storage, kind: nil)
    case .sync: String(localized: "Your library could not be synced first. Try again.", table: "SyncSettings")
    case .location: locationHeadline
    case .startup(let startup): headline(for: startup, kind: kind)
    case .journal: String(localized: "The record of the move on this device could not be read or saved.", table: "SyncSettings")
    }
  }

  private static func headline(for error: StorageError, kind: SyncProviderKind?) -> String {
    switch error {
    case .unauthenticated where kind == .s3:
      String(localized: "The storage did not accept these keys, or they may not list, read, write and delete in this bucket.", table: "SyncSettings")
    case .unauthenticated: String(localized: "The storage refused access. Check that you are signed in.", table: "SyncSettings")
    case .unavailable where kind == .localFolder: String(localized: "The folder cannot be used. Choose it again.", table: "SyncSettings")
    case .unavailable where kind == .s3:
      String(localized: "The storage could not be reached, or it has no such bucket. Check the endpoint, region and bucket, and that this device is online.", table: "SyncSettings")
    case .unavailable: String(localized: "The storage could not be reached. Check that this device is online.", table: "SyncSettings")
    case .quotaExceeded: String(localized: "The storage is full.", table: "SyncSettings")
    case .rateLimited: String(localized: "The storage is busy. Try again in a moment.", table: "SyncSettings")
    case .tooLarge: String(localized: "A file is too large for this storage.", table: "SyncSettings")
    case .underlying: String(localized: "The storage refused the request.", table: "SyncSettings")
    case .notFound, .alreadyExists, .keyConflict: String(localized: "The storage answered unexpectedly. Try again.", table: "SyncSettings")
    }
  }

  private static func headline(for error: SyncCredentialError) -> String {
    switch error {
    case .deviceLocked: lockedHeadline
    case .keychainUnavailable: teamlessHeadline
    case .keychain: keychainHeadline
    case .unreadable: String(localized: "The saved keys for this storage could not be read. Enter them again.", table: "SyncSettings")
    }
  }

  static var newerFormatHeadline: String {
    String(localized: "A newer version of Novel Forge wrote the library here. Update Novel Forge to use it.", table: "SyncSettings")
  }

  static var unrecognizedHeadline: String {
    String(localized: "This location holds sync files that belong to no library Novel Forge can identify. Choose another location.", table: "SyncSettings")
  }

  private static var lockedHeadline: String { String(localized: "Unlock this device, then try again.", table: "SyncSettings") }

  private static var keychainHeadline: String {
    String(localized: "The keychain could not be used, so sync cannot keep its keys. Check that Novel Forge may use it.", table: "SyncSettings")
  }

  private static var locationHeadline: String { String(localized: "Novel Forge could not save where your library syncs.", table: "SyncSettings") }
}
