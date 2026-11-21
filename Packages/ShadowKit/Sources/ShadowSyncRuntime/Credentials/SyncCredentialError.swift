import Foundation
import ShadowCore

public enum SyncCredentialError: ShadowError, Equatable {
  case deviceLocked
  case keychainUnavailable
  case keychain(String)
  case unreadable

  public var code: String {
    switch self {
    case .deviceLocked: "sync-credentials.device-locked"
    case .keychainUnavailable: "sync-credentials.keychain-unavailable"
    case .keychain: "sync-credentials.keychain"
    case .unreadable: "sync-credentials.unreadable"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .deviceLocked: "The credentials cannot be read until the device has been unlocked."
    case .keychainUnavailable: "The keychain refuses this build, which carries no application identifier, so the credentials cannot be kept."
    case .keychain(let reason): "The keychain could not be read or written (\(reason))."
    case .unreadable: "The stored credentials are unreadable; enter them again."
    }
  }
}
