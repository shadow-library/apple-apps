import Foundation
import ShadowCore

public enum VaultStateError: ShadowError, Equatable {
  case missingHeader
  case unsupportedVersion(Int64)
  case invalidJSON(line: Int)
  case malformedLine(line: Int)
  case outOfOrder(line: Int)
  case incompatibleRegistry(String)

  public var code: String {
    switch self {
    case .missingHeader: "vault_state.missing_header"
    case .unsupportedVersion: "vault_state.unsupported_version"
    case .invalidJSON: "vault_state.invalid_json"
    case .malformedLine: "vault_state.malformed_line"
    case .outOfOrder: "vault_state.out_of_order"
    case .incompatibleRegistry: "vault_state.incompatible_registry"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .missingHeader: "Vault state does not start with a header line."
    case .unsupportedVersion(let version): "Vault state version \(version) is not supported."
    case .invalidJSON(let line): "Line \(line) is not canonical JSON."
    case .malformedLine(let line): "Line \(line) is not a valid vault state line."
    case .outOfOrder(let line): "Line \(line) is duplicated or out of order."
    case .incompatibleRegistry(let reason): "The registry cannot carry this state additively: \(reason)."
    }
  }
}
