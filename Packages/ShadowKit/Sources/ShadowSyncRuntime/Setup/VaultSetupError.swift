import Foundation
import ShadowCore
import ShadowSync

public enum VaultSetupError: ShadowError, Equatable {
  case storage(StorageError)
  case keyRing(KeyRingError)
  case deviceLocked
  case vaultMismatch(expected: VaultID, found: VaultID)
  case vaultNotFound(VaultID)
  case newerFormat(Int64)
  case unrecognized
  case cancelled

  public var code: String {
    switch self {
    case .storage(let error): error.code
    case .keyRing(let error): error.code
    case .deviceLocked: "vault-setup.device-locked"
    case .vaultMismatch: "vault-setup.vault-mismatch"
    case .vaultNotFound: "vault-setup.vault-not-found"
    case .newerFormat: "vault-setup.newer-format"
    case .unrecognized: "vault-setup.unrecognized"
    case .cancelled: "vault-setup.cancelled"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .storage(let error): error.errorDescription
    case .keyRing(let error): error.errorDescription
    case .deviceLocked: "The keychain cannot be used until the device has been unlocked."
    case .vaultMismatch(let expected, let found): "This location holds vault \(found), not vault \(expected)."
    case .vaultNotFound(let vault): "Vault \(vault) is not at this location."
    case .newerFormat(let format): "The vault here was written in format \(format) by a newer version of the app. Update the app to use it."
    case .unrecognized: "This location holds vault files whose vault cannot be identified."
    case .cancelled: "The vault setup was cancelled before anything was written."
    }
  }

  init(keyRing error: KeyRingError) {
    self = error == .deviceLocked ? .deviceLocked : .keyRing(error)
  }
}
