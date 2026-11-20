import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

struct S3Failure: Sendable {
  private static let unauthenticatedCodes: Set<String> = [
    "AccessDenied", "AccountProblem", "AllAccessDisabled", "ExpiredToken", "InvalidAccessKeyId", "InvalidSecurity", "InvalidToken", "SignatureDoesNotMatch",
    "TokenRefreshRequired", "Unauthorized",
  ]
  private static let rateLimitCodes: Set<String> = ["SlowDown", "TooManyRequests", "RequestLimitExceeded", "Throttling", "ThrottlingException"]
  private static let misdirectedCodes: Set<String> = [
    "PermanentRedirect", "TemporaryRedirect", "Redirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException", "InvalidBucketName",
  ]
  private static let retryableCodes: Set<String> = [
    "InternalError", "ServiceUnavailable", "RequestTimeout", "OperationAborted", "BadDigest", "IncompleteBody", "XAmzContentSHA256Mismatch",
  ]
  private static let quotaMessages = ["storage cap exceeded", "quota exceeded", "storage quota"]
  private static let maximumMessageLength = 300

  let status: Int
  let code: String?
  let message: String?
  let headers: [String: String]

  init(status: Int, headers: [String: String], body: Data) {
    let error = S3XMLNode.parse(body).flatMap { $0.name == "Error" ? $0 : nil }
    self.init(status: status, code: error?.value("Code"), message: error?.value("Message"), headers: headers)
  }

  init(status: Int, code: String?, message: String?, headers: [String: String] = [:]) {
    self.status = status
    self.code = code.flatMap { $0.isEmpty ? nil : $0 }
    self.message = message
    self.headers = headers
  }

  func storageError(key: ObjectKey?, context: S3FailureContext) -> StorageError {
    if isQuota { return .quotaExceeded }
    if code == "RequestTimeTooSkewed" { return .unavailable(context.skewMessage(serverDate: headers["date"].flatMap(TrustedClock.parseHTTPDate))) }
    if code.map(Self.rateLimitCodes.contains) == true || status == 429 { return .rateLimited(retryAfter: retryAfter(now: context.now)) }
    if code == "NoSuchBucket" { return .unavailable("The bucket \(context.bucket) does not exist at this endpoint.") }
    if code.map(Self.unauthenticatedCodes.contains) == true || (code == nil && (status == 401 || status == 403)) { return .unauthenticated }
    if code.map(Self.misdirectedCodes.contains) == true || status == 301 || status == 307 { return .unavailable(misdirectedMessage(context)) }
    if let key, code == "NoSuchKey" || (code == nil && status == 404) { return .notFound(key) }
    if let key, code == "PreconditionFailed" || status == 412 { return .alreadyExists(key) }
    if let key, code == "EntityTooLarge" || status == 413 { return .tooLarge(key, limit: context.maxObjectBytes) }
    if code == "ConditionalRequestConflict" { return .unavailable("Another write to the same object was in progress; try again.") }
    if code == "NotImplemented" || status == 501 { return .underlying("The storage service does not support this request. \(describe(context))") }
    if code.map(Self.retryableCodes.contains) == true || status >= 500 || status == 408 || status == 409 { return .unavailable(describe(context)) }
    return .underlying(describe(context))
  }

  private var isQuota: Bool {
    if let code, code.hasSuffix("QuotaExceeded") { return true }
    guard let message = message?.lowercased() else { return false }
    return Self.quotaMessages.contains { message.contains($0) }
  }

  private func retryAfter(now: Date) -> Duration? {
    if let seconds = NetworkError.retryAfter(in: headers) { return seconds }
    guard let value = headers["retry-after"], let date = TrustedClock.parseHTTPDate(value.trimmingCharacters(in: .whitespaces)) else { return nil }
    return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
  }

  private func misdirectedMessage(_ context: S3FailureContext) -> String {
    let region = headers["x-amz-bucket-region"].map { " The bucket is in region \(context.redacting($0))." } ?? ""
    return "The bucket \(context.bucket) is not served at this endpoint and region.\(region) \(describe(context))"
  }

  private func describe(_ context: S3FailureContext) -> String {
    let summary = ["HTTP \(status)", code].compactMap(\.self).joined(separator: " ")
    guard let message, !message.isEmpty else { return summary }
    let flattened = context.redacting(message).unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
    let cleaned = String(String(flattened).split(separator: " ").joined(separator: " ").prefix(Self.maximumMessageLength))
    return "\(summary): \(cleaned)"
  }
}

struct S3FailureContext: Sendable {
  let bucket: String
  let maxObjectBytes: Int
  let now: Date
  let secrets: [String]

  init(bucket: String, maxObjectBytes: Int, now: Date, credentials: S3Credentials) {
    self.bucket = bucket
    self.maxObjectBytes = maxObjectBytes
    self.now = now
    secrets = [credentials.secretAccessKey, credentials.sessionToken, credentials.accessKeyID].compactMap(\.self).filter { !$0.isEmpty }
  }

  func redacting(_ text: String) -> String {
    secrets.reduce(text) { $0.replacingOccurrences(of: $1, with: "<redacted>") }
  }

  func skewMessage(serverDate: Date?) -> String {
    let advice = "S3 refuses requests signed more than 15 minutes away from its clock; set this device's date and time automatically, then try again."
    guard let serverDate else { return "This device's clock differs too much from the storage service's clock. \(advice)" }
    let minutes = Int((now.timeIntervalSince(serverDate) / 60).rounded())
    let direction = minutes >= 0 ? "ahead of" : "behind"
    return "This device's clock is about \(abs(minutes)) minutes \(direction) the storage service's clock. \(advice)"
  }
}

extension S3Failure {
  static func transport(_ error: any Error) -> StorageError {
    switch error {
    case is CancellationError: return .unavailable("The request was cancelled.")
    case let error as URLError where error.code == .cancelled: return .unavailable("The request was cancelled.")
    case let error as URLError: return .unavailable("The storage service could not be reached: \(error.localizedDescription)")
    case let error as NetworkError: return .unavailable(error.errorDescription ?? error.code)
    default: return .unavailable("The storage service could not be reached.")
    }
  }
}
