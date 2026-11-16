import Foundation
import ShadowCore

public enum KeyRingError: ShadowError, Equatable {
  case store(String)
  case conflictingKey(KeyID)

  public var code: String {
    switch self {
    case .store: "key-ring.store"
    case .conflictingKey: "key-ring.conflicting-key"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .store(let reason): "The keychain could not be read or written (\(reason))."
    case .conflictingKey(let keyID): "The keychain already holds different bytes for key \(keyID)."
    }
  }
}
