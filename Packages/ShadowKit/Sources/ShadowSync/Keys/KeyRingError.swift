import Foundation
import ShadowCore

public enum KeyRingError: ShadowError, Equatable {
  case store(String)
  case deviceLocked
  case keychainUnavailable
  case conflictingKey(KeyID)

  public var code: String {
    switch self {
    case .store: "key-ring.store"
    case .deviceLocked: "key-ring.device-locked"
    case .keychainUnavailable: "key-ring.keychain-unavailable"
    case .conflictingKey: "key-ring.conflicting-key"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let reason): "The keychain could not be read or written (\(reason))."
    case .deviceLocked: "The keychain cannot be read until the device has been unlocked once since it started."
    case .keychainUnavailable: "The keychain refuses this build, which carries no application identifier; sync needs a build signed with a team."
    case .conflictingKey(let keyID): "The keychain already holds different bytes for key \(keyID)."
    }
  }
}
