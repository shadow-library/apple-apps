import ShadowCore

public nonisolated enum VaultOpenError: ShadowError, Equatable {
  case locationUnavailable(String)
  case openFailed(String)

  public var code: String {
    switch self {
    case .locationUnavailable: "vault.location_unavailable"
    case .openFailed: "vault.open_failed"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .locationUnavailable(let reason), .openFailed(let reason): reason
    }
  }
}
