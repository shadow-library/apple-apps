import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

enum GoogleDriveFailure {
  private static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "RATE_LIMIT_EXCEEDED"]
  private static let quotaReasons: Set<String> = ["storageQuotaExceeded", "STORAGE_QUOTA_EXCEEDED"]
  private static let credentialReasons: Set<String> = ["authError", "insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]

  static func status(_ response: HTTPURLResponse, body: Data, now: Date = Date()) -> StorageError {
    let status = response.statusCode
    let reasons = DriveErrorBody.reasons(in: body)
    if status == 429 || (status == 403 && reasons.contains(where: rateLimitReasons.contains)) { return .rateLimited(retryAfter: retryAfter(response, now: now)) }
    if status == 403 && reasons.contains(where: quotaReasons.contains) { return .quotaExceeded }
    if status == 401 || (status == 403 && reasons.contains(where: credentialReasons.contains)) { return .unauthenticated }
    if (500..<600).contains(status) { return .unavailable("Google Drive responded with status \(status).") }
    let reason = reasons.first.map(sanitized).map { " (\($0))" } ?? ""
    return .underlying("Google Drive responded with status \(status)\(reason).")
  }

  static func transport(_ error: any Error) -> StorageError {
    switch error {
    case is CancellationError: return cancelled
    case let error as URLError: return urlError(error)
    case NetworkError.transport(let error): return urlError(error)
    case NetworkError.cancelled: return cancelled
    default: return .unavailable("Google Drive could not be reached.")
    }
  }

  static func oauth(_ error: OAuthError) -> StorageError {
    switch error {
    case .reauthorizationRequired, .notSignedIn, .accessDenied, .authorizationFailed, .stateMismatch, .redirectMismatch, .invalidCallback, .missingAuthorizationCode:
      .unauthenticated
    case .tokenRequestRejected(_, let code, _): code == nil ? .unavailable("Google sign-in returned an unexpected response.") : .unauthenticated
    case .rateLimited(let retryAfter): .rateLimited(retryAfter: retryAfter)
    case .serviceUnavailable, .transport: .unavailable("Google sign-in is unavailable.")
    case .malformedTokenResponse, .unsupportedTokenType, .underlying: .unavailable("Google sign-in returned an unexpected response.")
    case .cancelled: cancelled
    case .tokenStorage: .underlying("The Google sign-in tokens could not be loaded or saved.")
    case .invalidConfiguration: .underlying("The Google sign-in configuration is invalid.")
    }
  }

  static func malformed(_ what: String) -> StorageError {
    .underlying("Google Drive returned a malformed \(what).")
  }

  private static var cancelled: StorageError { .unavailable("The Google Drive request was cancelled.") }

  private static func urlError(_ error: URLError) -> StorageError {
    error.code == .cancelled ? cancelled : .unavailable("Google Drive could not be reached (URL error \(error.code.rawValue)).")
  }

  private static func retryAfter(_ response: HTTPURLResponse, now: Date) -> Duration? {
    let headers = response.lowercasedHeaderFields
    if let seconds = NetworkError.retryAfter(in: headers) { return seconds }
    guard let value = headers["retry-after"], let date = TrustedClock.parseHTTPDate(value.trimmingCharacters(in: .whitespaces)) else { return nil }
    return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
  }

  private static func sanitized(_ reason: String) -> String {
    String(reason.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }.prefix(64))
  }
}
