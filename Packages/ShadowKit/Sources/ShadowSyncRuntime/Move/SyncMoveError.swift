import Foundation
import ShadowCore
import ShadowSync

public enum SyncMoveError: ShadowError {
  case sameLocation
  case vaultMismatch(expected: VaultID, found: VaultID)
  /// A move starts only into a location that holds no vault files at all.
  case targetHoldsVault
  /// The location a move notice names does not hold this vault (yet).
  case targetMissingVault
  case targetKindMismatch(expected: SyncProviderKind, found: SyncProviderKind)
  case blobTooLarge(ObjectKey, size: Int, limit: Int)
  /// Another device moved the vault first; follow the notice instead.
  case alreadyMoved(VaultMoveNotice)
  /// A file is at the notice's name but does not open with this device's keys: a key may still be on its way, or the file is forged.
  case noticeUnreadable
  /// A different move is in progress on this device; it must finish first.
  case moveInProgress(SyncMoveJournal)
  /// A file read back from the new location does not match what was written, or does not open; the move stays where it was and can be run again.
  case verificationFailed(ObjectKey)
  /// The sync at the old location before the move could not upload this device's unsent changes yet.
  case sourceNotSettled
  case source(StorageError)
  case target(StorageError)
  case sync(SyncError)
  case location(SyncLocationError)
  case startup(SyncStartupError)
  case journal(String)

  public var code: String {
    switch self {
    case .sameLocation: "sync-move.same-location"
    case .vaultMismatch: "sync-move.vault-mismatch"
    case .targetHoldsVault: "sync-move.target-holds-vault"
    case .targetMissingVault: "sync-move.target-missing-vault"
    case .targetKindMismatch: "sync-move.target-kind-mismatch"
    case .blobTooLarge: "sync-move.blob-too-large"
    case .alreadyMoved: "sync-move.already-moved"
    case .noticeUnreadable: "sync-move.notice-unreadable"
    case .moveInProgress: "sync-move.move-in-progress"
    case .verificationFailed: "sync-move.verification-failed"
    case .sourceNotSettled: "sync-move.source-not-settled"
    case .source(let error): error.code
    case .target(let error): error.code
    case .sync(let error): error.code
    case .location(let error): error.code
    case .startup(let error): error.code
    case .journal: "sync-move.journal"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .sameLocation: "The vault already syncs with this location."
    case .vaultMismatch(let expected, let found): "The move is for vault \(found), but this device syncs vault \(expected)."
    case .targetHoldsVault: "The new location already holds vault files; a vault moves only into an empty location."
    case .targetMissingVault: "The location the vault moved to does not hold the vault yet."
    case .targetKindMismatch(let expected, let found): "The vault moved to a \(expected.rawValue) location, not a \(found.rawValue) one."
    case .blobTooLarge(let key, let size, let limit): "The file \(key) has \(size) bytes, more than the \(limit) the new location accepts."
    case .alreadyMoved: "Another device has already moved this vault to a new location."
    case .noticeUnreadable: "A move notice is stored here but cannot be opened with this device's keys."
    case .moveInProgress: "Another move of this vault is still in progress on this device."
    case .verificationFailed(let key): "The file \(key) read back from the new location does not match what was written."
    case .sourceNotSettled: "This device's unsent changes could not be uploaded to the old location yet, so the move waits."
    case .source(let error): error.errorDescription
    case .target(let error): error.errorDescription
    case .sync(let error): error.errorDescription
    case .location(let error): error.errorDescription
    case .startup(let error): error.errorDescription
    case .journal(let reason): "The record of the move in progress could not be read or saved (\(reason))."
    }
  }
}

public enum SyncMoveOutcome: Sendable, Equatable {
  /// This database now syncs at `location` as `replica`; start a new engine there.
  case moved(replica: ReplicaID, location: SyncLocation)
  /// Another device's move was recorded first: follow `notice`. Nothing this attempt wrote is removed.
  case superseded(VaultMoveNotice)
}
