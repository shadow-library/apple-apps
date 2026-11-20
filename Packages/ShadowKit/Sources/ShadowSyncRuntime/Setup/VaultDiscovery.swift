import Foundation
import ShadowSync

public enum VaultDiscovery: Sendable, Equatable {
  /// The provider answered that it holds no vault file at all; only then may a vault be created without asking.
  case empty
  /// Named by the plaintext hint, or by a manifest header when the hint is missing or unreadable; neither is authenticated.
  case found(VaultID)
  case newerFormat(Int64)
  /// Vault files are listed but nothing names their vault.
  case unrecognized
}

public enum VaultCreation: Sendable, Equatable {
  case created(VaultID, key: KeyID)
  /// Another device's vault was there first; this device holds no key for it until the keychain delivers one.
  case joined(VaultID)

  public var vault: VaultID {
    switch self {
    case .created(let vault, _), .joined(let vault): vault
    }
  }
}
