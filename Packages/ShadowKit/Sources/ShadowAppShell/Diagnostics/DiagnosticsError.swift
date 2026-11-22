import ShadowCore
import ShadowStore

nonisolated enum DiagnosticsError: DomainFailure, Equatable {
  case encoding
  case file(String)
  case zip(String)
  case logUnavailable(String)

  var code: String {
    switch self {
    case .encoding: "diagnostics.encoding"
    case .file: "diagnostics.file"
    case .zip: "diagnostics.zip"
    case .logUnavailable: "diagnostics.log_unavailable"
    }
  }

  var errorDescription: String? {
    switch self {
    case .encoding: "The diagnostics summary could not be encoded."
    case .file(let reason), .zip(let reason), .logUnavailable(let reason): reason
    }
  }

  var storeFailure: StoreError? { nil }
}
