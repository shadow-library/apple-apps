import ShadowCore

nonisolated enum VaultOpenError: ShadowError, Equatable {
  case locationUnavailable(String)
  case openFailed(String)

  var code: String {
    switch self {
    case .locationUnavailable: "vault.location_unavailable"
    case .openFailed: "vault.open_failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case .locationUnavailable(let reason), .openFailed(let reason): reason
    }
  }
}
