import Foundation

import ShadowCore

public enum VaultFileError: ShadowError, Equatable {
  case invalidMagic
  case unsupportedVersion(UInt8)
  case unsupportedFlags(UInt8)
  case truncatedHeader
  case invalidVaultID
  case invalidChunkSize(Int)
  case pathTooLong
  case vaultMismatch(expected: VaultID, found: VaultID)
  case keyUnavailable(KeyID)
  case authenticationFailed
  case truncated
  case trailingData
  case invalidChunkLength
  case tooManyChunks
  case alreadyFinalized
  case cryptoFailure

  public var code: String {
    switch self {
    case .invalidMagic: "vault-file.invalid-magic"
    case .unsupportedVersion: "vault-file.unsupported-version"
    case .unsupportedFlags: "vault-file.unsupported-flags"
    case .truncatedHeader: "vault-file.truncated-header"
    case .invalidVaultID: "vault-file.invalid-vault-id"
    case .invalidChunkSize: "vault-file.invalid-chunk-size"
    case .pathTooLong: "vault-file.path-too-long"
    case .vaultMismatch: "vault-file.vault-mismatch"
    case .keyUnavailable: "vault-file.key-unavailable"
    case .authenticationFailed: "vault-file.authentication-failed"
    case .truncated: "vault-file.truncated"
    case .trailingData: "vault-file.trailing-data"
    case .invalidChunkLength: "vault-file.invalid-chunk-length"
    case .tooManyChunks: "vault-file.too-many-chunks"
    case .alreadyFinalized: "vault-file.already-finalized"
    case .cryptoFailure: "vault-file.crypto-failure"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidMagic: "The data is not a vault file."
    case .unsupportedVersion(let version): "Vault file format version \(version) is not supported."
    case .unsupportedFlags(let flags): "Vault file flags \(flags) are not supported."
    case .truncatedHeader: "The vault file header is incomplete."
    case .invalidVaultID: "The vault file names an invalid vault id."
    case .invalidChunkSize(let size): "Chunk size \(size) is outside 1...\(VaultFile.maximumChunkSize)."
    case .pathTooLong: "The file path is too long."
    case .vaultMismatch(let expected, let found): "The file belongs to vault \(found), not \(expected)."
    case .keyUnavailable(let keyID): "Key \(keyID) is not in the key ring."
    case .authenticationFailed: "The vault file failed authentication."
    case .truncated: "The vault file is truncated."
    case .trailingData: "The vault file has data after its final chunk."
    case .invalidChunkLength: "A vault file chunk has an invalid length."
    case .tooManyChunks: "The vault file exceeds the chunk counter."
    case .alreadyFinalized: "The final chunk was already sealed."
    case .cryptoFailure: "The cryptographic operation failed."
    }
  }
}
