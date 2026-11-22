import Foundation
import ShadowCore
import ShadowKeychain
import ShadowSync
import ShadowSyncRuntime

/// The words for a failure of a settings action: a headline for the user and the error's code for support. `kind` is the storage the action talked to.
struct SyncSettingsErrors {
  let app: AppIdentity

  func presented(_ error: any Error, kind: SyncProviderKind?) -> PresentedError {
    PresentedError(headline: Self.isKeychainRefusal(error) ? teamlessHeadline : headline(for: error, kind: kind), detail: Self.code(of: error))
  }

  var teamlessHeadline: String {
    String(localized: "This build of \(app.displayName) cannot use the keychain on this device, so it cannot sync.", table: "SyncSettings", bundle: .module)
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

  private func headline(for error: any Error, kind: SyncProviderKind?) -> String {
    switch error {
    case let error as SyncStartupError: headline(for: error, kind: kind)
    case let error as VaultSetupError: headline(for: error, kind: kind)
    case let error as SyncMoveError: headline(for: error, kind: kind)
    case let error as StorageError: headline(for: error, kind: kind)
    case let error as SyncCredentialError: headline(for: error)
    case is SecureStoreError, is KeyRingError: keychainHeadline
    case is SyncLocationError: locationHeadline
    default: String(localized: "Something went wrong.", table: "SyncSettings", bundle: .module)
    }
  }

  private func headline(for error: SyncStartupError, kind: SyncProviderKind?) -> String {
    switch error {
    case .deviceLocked: lockedHeadline
    case .keychainUnavailable: teamlessHeadline
    case .noStorageAccount where kind == .iCloud: String(localized: "Sign in to iCloud on this device first.", table: "SyncSettings", bundle: .module)
    case .noStorageAccount: String(localized: "No account is signed in for this storage.", table: "SyncSettings", bundle: .module)
    case .accountUnavailable: String(localized: "The storage account cannot be reached right now. Try again later.", table: "SyncSettings", bundle: .module)
    case .alreadyAttached: String(localized: "Sync was turned on meanwhile, perhaps in another window.", table: "SyncSettings", bundle: .module)
    case .notAttached: String(localized: "Sync was turned off meanwhile, perhaps in another window.", table: "SyncSettings", bundle: .module)
    case .location: locationHeadline
    case .setup(let setup): headline(for: setup, kind: kind)
    case .storage(let storage): headline(for: storage, kind: kind)
    case .keyRing, .marker: keychainHeadline
    case .unavailable: String(localized: "Sync cannot run right now. Resolve the problem shown above first.", table: "SyncSettings", bundle: .module)
    }
  }

  private func headline(for error: VaultSetupError, kind: SyncProviderKind?) -> String {
    switch error {
    case .storage(let storage): headline(for: storage, kind: kind)
    case .keyRing: keychainHeadline
    case .deviceLocked: lockedHeadline
    case .vaultMismatch: String(localized: "This location now holds a different \(app.vaultNoun). Look at it again before joining.", table: "SyncSettings", bundle: .module)
    case .vaultNotFound: String(localized: "The \(app.vaultNoun) is no longer at this location. Look at it again.", table: "SyncSettings", bundle: .module)
    case .newerFormat: newerFormatHeadline
    case .unrecognized: unrecognizedHeadline
    case .cancelled: String(localized: "Setting up sync was cancelled before anything was written.", table: "SyncSettings", bundle: .module)
    }
  }

  private func headline(for error: SyncMoveError, kind: SyncProviderKind?) -> String {
    switch error {
    case .sameLocation: String(localized: "Your \(app.vaultNoun) already syncs here. Choose another location.", table: "SyncSettings", bundle: .module)
    case .vaultMismatch: String(localized: "That move is for another \(app.vaultNoun).", table: "SyncSettings", bundle: .module)
    case .targetHoldsVault:
      String(localized: "That location already holds a synced \(app.vaultNoun). A \(app.vaultNoun) moves only into an empty location.", table: "SyncSettings", bundle: .module)
    case .targetMissingVault:
      String(
        localized: "Your \(app.vaultNoun) is not at that location yet. Check that it is where your other device moved it, or try again later.", table: "SyncSettings",
        bundle: .module)
    case .targetKindMismatch: String(localized: "Your \(app.vaultNoun) moved to another kind of storage.", table: "SyncSettings", bundle: .module)
    case .blobTooLarge: String(localized: "A file in your \(app.vaultNoun) is too large for that storage.", table: "SyncSettings", bundle: .module)
    case .alreadyMoved: String(localized: "Another device has already moved your \(app.vaultNoun). Follow it instead.", table: "SyncSettings", bundle: .module)
    case .noticeUnreadable:
      String(localized: "A move notice is there, but this device cannot open it yet; its key may still be on its way.", table: "SyncSettings", bundle: .module)
    case .moveInProgress: String(localized: "Another move is still in progress on this device. Finish or abandon it first.", table: "SyncSettings", bundle: .module)
    case .verificationFailed:
      String(localized: "What was copied did not read back correctly. Your \(app.vaultNoun) still syncs where it did; try again.", table: "SyncSettings", bundle: .module)
    case .sourceNotSettled: String(localized: "This device's latest changes could not be sent first. Try again once sync is up to date.", table: "SyncSettings", bundle: .module)
    case .source(let storage): headline(for: storage, kind: nil)
    case .target(let storage): headline(for: storage, kind: kind)
    case .sync(.awaitingKey): String(localized: "This device does not have your \(app.vaultNoun)'s key yet.", table: "SyncSettings", bundle: .module)
    case .sync(.keyRing(.deviceLocked)): lockedHeadline
    case .sync(.keyRing): keychainHeadline
    case .sync(.storage(let storage)): headline(for: storage, kind: nil)
    case .sync: String(localized: "Your \(app.vaultNoun) could not be synced first. Try again.", table: "SyncSettings", bundle: .module)
    case .location: locationHeadline
    case .startup(let startup): headline(for: startup, kind: kind)
    case .journal: String(localized: "The record of the move on this device could not be read or saved.", table: "SyncSettings", bundle: .module)
    }
  }

  private func headline(for error: StorageError, kind: SyncProviderKind?) -> String {
    switch error {
    case .unauthenticated where kind == .s3:
      String(localized: "The storage did not accept these keys, or they may not list, read, write and delete in this bucket.", table: "SyncSettings", bundle: .module)
    case .unauthenticated: String(localized: "The storage refused access. Check that you are signed in.", table: "SyncSettings", bundle: .module)
    case .unavailable where kind == .localFolder: String(localized: "The folder cannot be used. Choose it again.", table: "SyncSettings", bundle: .module)
    case .unavailable where kind == .s3:
      String(
        localized: "The storage could not be reached, or it has no such bucket. Check the endpoint, region and bucket, and that this device is online.", table: "SyncSettings",
        bundle: .module)
    case .unavailable: String(localized: "The storage could not be reached. Check that this device is online.", table: "SyncSettings", bundle: .module)
    case .quotaExceeded: String(localized: "The storage is full.", table: "SyncSettings", bundle: .module)
    case .rateLimited: String(localized: "The storage is busy. Try again in a moment.", table: "SyncSettings", bundle: .module)
    case .tooLarge: String(localized: "A file is too large for this storage.", table: "SyncSettings", bundle: .module)
    case .underlying: String(localized: "The storage refused the request.", table: "SyncSettings", bundle: .module)
    case .notFound, .alreadyExists, .keyConflict: String(localized: "The storage answered unexpectedly. Try again.", table: "SyncSettings", bundle: .module)
    }
  }

  private func headline(for error: SyncCredentialError) -> String {
    switch error {
    case .deviceLocked: lockedHeadline
    case .keychainUnavailable: teamlessHeadline
    case .keychain: keychainHeadline
    case .unreadable: String(localized: "The saved keys for this storage could not be read. Enter them again.", table: "SyncSettings", bundle: .module)
    }
  }

  var newerFormatHeadline: String {
    String(localized: "A newer version of \(app.displayName) wrote the \(app.vaultNoun) here. Update \(app.displayName) to use it.", table: "SyncSettings", bundle: .module)
  }

  var unrecognizedHeadline: String {
    String(
      localized: "This location holds sync files that belong to no \(app.vaultNoun) \(app.displayName) can identify. Choose another location.", table: "SyncSettings",
      bundle: .module)
  }

  private var lockedHeadline: String { String(localized: "Unlock this device, then try again.", table: "SyncSettings", bundle: .module) }

  private var keychainHeadline: String {
    String(localized: "The keychain could not be used, so sync cannot keep its keys. Check that \(app.displayName) may use it.", table: "SyncSettings", bundle: .module)
  }

  private var locationHeadline: String { String(localized: "\(app.displayName) could not save where your \(app.vaultNoun) syncs.", table: "SyncSettings", bundle: .module) }
}
