import ShadowCore

nonisolated enum MemoirVaultOpenError: ShadowError, Equatable {
  case locationUnavailable(String)
  case buildVersionUnavailable
  case openFailed(String)

  var code: String {
    switch self {
    case .locationUnavailable: "memoir_vault.location_unavailable"
    case .buildVersionUnavailable: "memoir_vault.build_version_unavailable"
    case .openFailed: "memoir_vault.open_failed"
    }
  }

  var errorDescription: String? {
    switch self {
    case .locationUnavailable(let reason), .openFailed(let reason): reason
    case .buildVersionUnavailable: "the app bundle has no CFBundleVersion"
    }
  }
}
