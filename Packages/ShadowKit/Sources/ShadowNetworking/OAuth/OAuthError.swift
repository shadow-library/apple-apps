import Foundation
import ShadowCore

public enum OAuthError: ShadowError, Equatable {
  case invalidConfiguration(String)
  case redirectMismatch
  case invalidCallback(String)
  case stateMismatch
  case accessDenied(description: String?)
  case authorizationFailed(error: String, description: String?)
  case missingAuthorizationCode
  case reauthorizationRequired
  case tokenRequestRejected(status: Int, error: String?, description: String?)
  case malformedTokenResponse(String)
  case unsupportedTokenType(String)
  case rateLimited(retryAfter: Duration?)
  case serviceUnavailable(status: Int, retryAfter: Duration?)
  case transport(URLError)
  case cancelled
  case notSignedIn
  case tokenStorage(String)
  case underlying(String)

  public var code: String {
    switch self {
    case .invalidConfiguration: "oauth.invalid_configuration"
    case .redirectMismatch: "oauth.redirect_mismatch"
    case .invalidCallback: "oauth.invalid_callback"
    case .stateMismatch: "oauth.state_mismatch"
    case .accessDenied: "oauth.access_denied"
    case .authorizationFailed: "oauth.authorization_failed"
    case .missingAuthorizationCode: "oauth.missing_authorization_code"
    case .reauthorizationRequired: "oauth.reauthorization_required"
    case .tokenRequestRejected: "oauth.token_request_rejected"
    case .malformedTokenResponse: "oauth.malformed_token_response"
    case .unsupportedTokenType: "oauth.unsupported_token_type"
    case .rateLimited: "oauth.rate_limited"
    case .serviceUnavailable: "oauth.service_unavailable"
    case .transport: "oauth.transport"
    case .cancelled: "oauth.cancelled"
    case .notSignedIn: "oauth.not_signed_in"
    case .tokenStorage: "oauth.token_storage"
    case .underlying: "oauth.underlying"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let reason): "The sign-in configuration is invalid: \(reason)"
    case .redirectMismatch: "The sign-in returned to an address other than the registered redirect."
    case .invalidCallback(let reason): "The sign-in callback is invalid: \(reason)"
    case .stateMismatch: "The sign-in callback does not belong to the sign-in that was started."
    case .accessDenied: "The sign-in was declined."
    case .authorizationFailed(let error, _): "The sign-in failed with \(error)."
    case .missingAuthorizationCode: "The sign-in returned no authorization code."
    case .reauthorizationRequired: "The account must be signed in again."
    case .tokenRequestRejected(let status, let error, _): "The token request was rejected with status \(status)\(error.map { " (\($0))" } ?? "")."
    case .malformedTokenResponse(let reason): "The token response is malformed: \(reason)"
    case .unsupportedTokenType(let type): "The token type \(type) is not supported."
    case .rateLimited: "The sign-in service asked to slow down."
    case .serviceUnavailable(let status, _): "The sign-in service is unavailable (status \(status))."
    case .transport(let error): error.localizedDescription
    case .cancelled: "The sign-in request was cancelled."
    case .notSignedIn: "No account is signed in."
    case .tokenStorage(let reason): "The sign-in tokens could not be stored: \(reason)"
    case .underlying(let reason): reason
    }
  }

  public var isRetryable: Bool {
    switch self {
    case .rateLimited, .serviceUnavailable, .transport: true
    default: false
    }
  }

  public var retryAfter: Duration? {
    switch self {
    case .rateLimited(let retryAfter), .serviceUnavailable(_, let retryAfter): retryAfter
    default: nil
    }
  }
}
