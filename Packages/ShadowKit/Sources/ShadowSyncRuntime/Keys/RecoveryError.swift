import Foundation
import ShadowCore
import ShadowStore
import ShadowSync

public enum RecoveryError: ShadowError, Equatable {
  case deviceLocked
  case keyRing(KeyRingError)
  case storage(StorageError)
  case store(String)
  case envelope(KeyEnvelopeError)
  case noRingKey
  case confirmationMismatch(positions: [Int])
  case setupFinished
  /// Wrong phrase, wrong vault, or no recovery set up: the location holds no copy sealed to the recipient the phrase derives for this vault.
  case noRecoveryCopies
  /// Every copy found failed authentication, names another vault or sits under another key's name.
  case recoveryCopiesRefused
  /// The copies opened, but none of their keys opened a file at this location yet, so none joined the ring.
  case keysUnconfirmed([KeyID])

  public var code: String {
    switch self {
    case .deviceLocked: "recovery.device-locked"
    case .keyRing(let error): error.code
    case .storage(let error): error.code
    case .store: "recovery.store"
    case .envelope(let error): error.code
    case .noRingKey: "recovery.no-ring-key"
    case .confirmationMismatch: "recovery.confirmation-mismatch"
    case .setupFinished: "recovery.setup-finished"
    case .noRecoveryCopies: "recovery.no-recovery-copies"
    case .recoveryCopiesRefused: "recovery.copies-refused"
    case .keysUnconfirmed: "recovery.keys-unconfirmed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .deviceLocked: "The keychain cannot be used until the device has been unlocked."
    case .keyRing(let error): error.errorDescription
    case .storage(let error): error.errorDescription
    case .store(let reason): "The vault could not be read or written (\(reason))."
    case .envelope(let error): error.errorDescription
    case .noRingKey: "This device holds no key for the vault yet, so recovery cannot be set up here."
    case .confirmationMismatch(let positions): "Words \(positions.map(String.init).joined(separator: ", ")) do not match the recovery phrase."
    case .setupFinished: "This recovery phrase was already set up; start again to make a new one."
    case .noRecoveryCopies: "No keys for this vault are sealed to that recovery phrase."
    case .recoveryCopiesRefused: "The sealed keys found for that recovery phrase are not genuine."
    case .keysUnconfirmed(let keys): "\(keys.count) recovered keys open no file at this location yet, so they were not added."
    }
  }

  init(_ error: KeyRingError) {
    self = error == .deviceLocked ? .deviceLocked : .keyRing(error)
  }

  init(_ error: StoreError) {
    self = .store(error.code)
  }

  init(_ error: RecoveryCopiesError) {
    switch error {
    case .storage(let error): self = .storage(error)
    case .store(let reason): self = .store(reason)
    case .envelope(let error): self = .envelope(error)
    }
  }
}
