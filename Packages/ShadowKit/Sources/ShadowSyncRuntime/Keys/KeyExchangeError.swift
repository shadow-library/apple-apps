import Foundation
import ShadowCore
import ShadowSync

public enum KeyExchangeError: ShadowError, Equatable {
  case envelope(KeyEnvelopeError)
  case deviceLocked
  case keyRing(KeyRingError)
  case storage(StorageError)
  case noRingKey
  case requestReplayed
  case awaitingResponse
  /// The codes differed, so the response may not come from the device the user scanned; nothing was added and the exchange is over.
  case codeMismatch
  case exchangeAborted
  case exchangeFinished
  /// The code matched, but none of the received keys opened a file at this location yet, so none joined the ring.
  case keysUnconfirmed([KeyID])

  public var code: String {
    switch self {
    case .envelope(let error): error.code
    case .deviceLocked: "key-exchange.device-locked"
    case .keyRing(let error): error.code
    case .storage(let error): error.code
    case .noRingKey: "key-exchange.no-ring-key"
    case .requestReplayed: "key-exchange.request-replayed"
    case .awaitingResponse: "key-exchange.awaiting-response"
    case .codeMismatch: "key-exchange.code-mismatch"
    case .exchangeAborted: "key-exchange.aborted"
    case .exchangeFinished: "key-exchange.finished"
    case .keysUnconfirmed: "key-exchange.keys-unconfirmed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .envelope(let error): error.errorDescription
    case .deviceLocked: "The keychain cannot be used until the device has been unlocked."
    case .keyRing(let error): error.errorDescription
    case .storage(let error): error.errorDescription
    case .noRingKey: "This device holds no key for the vault, so it cannot send one."
    case .requestReplayed: "This device already answered that code; show a new one on the other device."
    case .awaitingResponse: "Scan the other device's code first."
    case .codeMismatch: "The codes do not match, so no key was added. Start again on both devices."
    case .exchangeAborted: "This exchange was stopped; start a new one."
    case .exchangeFinished: "This exchange is already complete."
    case .keysUnconfirmed(let keys): "\(keys.count) received keys open no file at this location yet, so they were not added."
    }
  }

  init(_ error: KeyRingError) {
    self = error == .deviceLocked ? .deviceLocked : .keyRing(error)
  }
}
