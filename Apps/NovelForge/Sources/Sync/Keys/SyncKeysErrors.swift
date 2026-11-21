import Foundation
import ShadowCore
import ShadowSync
import ShadowSyncRuntime

/// The words for a key screen's failure: a headline for the user and the error's code for support.
enum SyncKeysErrors {
  static func presented(_ error: SyncKeysError) -> PresentedError {
    PresentedError(headline: headline(for: error), detail: error.code)
  }

  static func headline(for error: SyncKeysError) -> String {
    switch error {
    case .services(let error): headline(for: error)
    case .recovery(let error): headline(for: error)
    case .exchange(let error): headline(for: error)
    case .phrase(let error): headline(for: error)
    case .vaultChanged: changedHeadline
    }
  }

  /// Why the key services are not there at all; nil for a phase that comes with them.
  static func unavailable(_ phase: SyncPhase?) -> String {
    switch phase {
    case .detached?, .settingsUnreadable?: String(localized: "Sync is off on this device. Turn it on to bring your library's key here.", table: "SyncKeys")
    case .deviceLocked?: lockedHeadline
    case .keychainUnavailable?: teamlessHeadline
    case nil: String(localized: "Your library's keys can be managed once sync has started.", table: "SyncKeys")
    default: String(localized: "Sync cannot reach your library's synced copy right now. The sync status says why.", table: "SyncKeys")
    }
  }

  private static func headline(for error: SyncStartupError) -> String {
    switch error {
    case .unavailable(let phase): unavailable(phase)
    case .notAttached: unavailable(nil)
    case .deviceLocked: lockedHeadline
    case .keychainUnavailable, .keyRing(.keychainUnavailable): teamlessHeadline
    default: String(localized: "Sync could not open your library's keys. Try again.", table: "SyncKeys")
    }
  }

  private static func headline(for error: RecoveryError) -> String {
    switch error {
    case .deviceLocked: lockedHeadline
    case .keyRing(.keychainUnavailable): teamlessHeadline
    case .keyRing: keychainHeadline
    case .storage(let storage): headline(for: storage)
    case .store: String(localized: "Your library could not be read or saved on this device.", table: "SyncKeys")
    case .envelope: String(localized: "The keys stored for this phrase could not be read.", table: "SyncKeys")
    case .noRingKey: String(localized: "This device does not hold your library's key, so it cannot set up a recovery phrase.", table: "SyncKeys")
    case .confirmationMismatch(let positions):
      String(localized: "Words \(positions.map(String.init).formatted(.list(type: .and))) do not match. Check what you wrote down.", table: "SyncKeys")
    case .setupFinished: String(localized: "This recovery phrase is already saved. Start again to make a new one.", table: "SyncKeys")
    case .noRecoveryCopies:
      String(
        localized: "This phrase does not unlock this library. It may belong to another library, or a newer phrase may have replaced it.", table: "SyncKeys")
    case .recoveryCopiesRefused: String(localized: "The keys stored for this phrase failed a check, so none were added.", table: "SyncKeys")
    case .keysUnconfirmed: unconfirmedHeadline
    case .unavailable: changedHeadline
    }
  }

  private static func headline(for error: KeyExchangeError) -> String {
    switch error {
    case .envelope(.corruptText), .envelope(.malformed), .envelope(.unsupportedVersion):
      String(localized: "That code could not be read. Scan it again.", table: "SyncKeys")
    case .envelope(.vaultMismatch): String(localized: "The other device sent the key of another library, so nothing was added. Start again.", table: "SyncKeys")
    case .envelope(.requestMismatch): String(localized: "That code answers another request. Scan the code the other device shows for this one.", table: "SyncKeys")
    case .envelope(.sessionSpent), .exchangeAborted: String(localized: "This exchange has ended. Start again on both devices.", table: "SyncKeys")
    case .envelope(.authenticationFailed): String(localized: "That code failed a check, so nothing was added. Start again on both devices.", table: "SyncKeys")
    case .envelope: String(localized: "That code could not be used. Start again on both devices.", table: "SyncKeys")
    case .deviceLocked: lockedHeadline
    case .keyRing(.keychainUnavailable): teamlessHeadline
    case .keyRing: keychainHeadline
    case .storage(let storage): headline(for: storage)
    case .noRingKey: String(localized: "This device does not hold your library's key, so it cannot send it.", table: "SyncKeys")
    case .requestReplayed: String(localized: "This device already answered that code. Start again on the other device to show a new one.", table: "SyncKeys")
    case .awaitingResponse: String(localized: "Scan the other device's code first.", table: "SyncKeys")
    case .codeMismatch: String(localized: "The codes do not match, so no key was added. Start again on both devices.", table: "SyncKeys")
    case .exchangeFinished: String(localized: "This exchange is already complete.", table: "SyncKeys")
    case .keysUnconfirmed: unconfirmedHeadline
    case .unavailable: changedHeadline
    }
  }

  private static func headline(for error: RecoveryPhraseError) -> String {
    switch error {
    case .wrongWordCount(let found): String(localized: "A recovery phrase has 24 words, and this has \(found).", table: "SyncKeys")
    case .unknownWord(let position): String(localized: "Word \(position) is not a recovery phrase word. Check its spelling.", table: "SyncKeys")
    case .badChecksum: String(localized: "These words are not a valid recovery phrase. A word may be wrong or out of order.", table: "SyncKeys")
    }
  }

  private static func headline(for error: StorageError) -> String {
    switch error {
    case .unauthenticated: String(localized: "The sync storage refused access. Check that you are signed in.", table: "SyncKeys")
    case .rateLimited: String(localized: "The sync storage is busy. Try again in a moment.", table: "SyncKeys")
    default: String(localized: "The sync storage could not be reached. Check that this device is online, then try again.", table: "SyncKeys")
    }
  }

  private static var changedHeadline: String {
    String(localized: "Sync changed while this was open, so it stopped. Nothing was changed.", table: "SyncKeys")
  }

  private static var unconfirmedHeadline: String {
    String(
      localized: "The key arrived, but it opens nothing in your library's synced copy yet. Try again once your other devices have synced.", table: "SyncKeys")
  }

  private static var lockedHeadline: String { String(localized: "Unlock this device, then try again.", table: "SyncKeys") }

  private static var teamlessHeadline: String {
    String(localized: "This build of Novel Forge cannot use the keychain on this device, so it cannot keep your library's key.", table: "SyncKeys")
  }

  private static var keychainHeadline: String {
    String(localized: "The keychain could not be used, so your library's key cannot be kept here.", table: "SyncKeys")
  }
}
