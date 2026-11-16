import Foundation
import ShadowCore

public enum KeyEnvelopeError: ShadowError, Equatable {
  case malformed
  case unsupportedVersion(UInt8)
  case unexpectedKind(UInt8)
  case vaultMismatch(expected: VaultID, found: VaultID)
  case requestMismatch
  case sessionSpent
  case authenticationFailed
  case corruptText
  case invalidKeyCount(Int)
  case duplicateKeyID(KeyID)
  case cryptoFailure

  public var code: String {
    switch self {
    case .malformed: "key-envelope.malformed"
    case .unsupportedVersion: "key-envelope.unsupported-version"
    case .unexpectedKind: "key-envelope.unexpected-kind"
    case .vaultMismatch: "key-envelope.vault-mismatch"
    case .requestMismatch: "key-envelope.request-mismatch"
    case .sessionSpent: "key-envelope.session-spent"
    case .authenticationFailed: "key-envelope.authentication-failed"
    case .corruptText: "key-envelope.corrupt-text"
    case .invalidKeyCount: "key-envelope.invalid-key-count"
    case .duplicateKeyID: "key-envelope.duplicate-key-id"
    case .cryptoFailure: "key-envelope.crypto-failure"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .malformed: "The sealed key data is malformed."
    case .unsupportedVersion(let version): "Sealed key format version \(version) is not supported."
    case .unexpectedKind(let kind): "The code is of kind \(kind), which was not expected here."
    case .vaultMismatch(let expected, let found): "The sealed keys belong to vault \(found), not \(expected)."
    case .requestMismatch: "The response answers a different request."
    case .sessionSpent: "This request has already been answered; start a new one."
    case .authenticationFailed: "The sealed keys failed authentication."
    case .corruptText: "The code was not read correctly."
    case .invalidKeyCount(let count): "\(count) keys is outside 1...\(KeyExchangeResponse.maximumKeys)."
    case .duplicateKeyID(let keyID): "Key \(keyID) appears more than once."
    case .cryptoFailure: "The cryptographic operation failed."
    }
  }
}
