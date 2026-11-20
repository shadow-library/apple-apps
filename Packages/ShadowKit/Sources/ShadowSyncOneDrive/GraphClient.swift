import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

struct GraphResponse: Sendable {
  let status: Int
  let headers: [String: String]
  let body: Data

  var isSuccess: Bool { (200..<300).contains(status) }
  var codes: [String] { GraphErrorBody.codes(in: body) }
}

/// Sends Graph requests with the session's bearer token, and pre-authenticated download and upload requests without one.
/// Error text never carries an address: delta links and pre-authenticated addresses hold secrets of their own.
struct GraphClient: Sendable {
  let base: URL
  let session: OAuthSession
  let transport: any HTTPTransport
  let now: @Sendable () -> Date

  func url(_ path: String) -> URL? {
    URL(string: base.absoluteString + path)
  }

  func authorized(_ request: URLRequest) async throws(StorageError) -> GraphResponse {
    guard let url = request.url, url.scheme == "https", url.host() == base.host() else { throw .underlying("refusing to send the Microsoft token outside Microsoft Graph") }
    let token = try await Self.converting { () async throws(OAuthError) in try await session.accessToken() }
    let first = try await send(request, token: token)
    guard first.status == 401 else { return first }
    let renewed = try await Self.converting { () async throws(OAuthError) in try await session.refreshAfterRejection(of: token) }
    let second = try await send(request, token: renewed)
    guard second.status == 401 else { return second }
    throw .unauthenticated
  }

  func anonymous(_ request: URLRequest) async throws(StorageError) -> GraphResponse {
    guard request.url?.scheme == "https" else { throw .underlying("a pre-authenticated OneDrive address is not https") }
    var request = request
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    return try await exchange(request)
  }

  func failure(_ response: GraphResponse) -> StorageError {
    let codes = response.codes
    return Self.failure(status: response.status, headers: response.headers, codes: codes, now: now())
  }

  static func failure(status: Int, headers: [String: String], codes: [String], now: Date) -> StorageError {
    let retryAfter = retryAfter(in: headers, now: now)
    if status == 507 || codes.contains("quotaLimitReached") || codes.contains("insufficientStorage") { return .quotaExceeded }
    if status == 429 || codes.contains("activityLimitReached") { return .rateLimited(retryAfter: retryAfter) }
    if status == 503, retryAfter != nil { return .rateLimited(retryAfter: retryAfter) }
    if status == 501 || status == 505 || codes.contains("notSupported") || codes.contains("notImplemented") {
      return .underlying("Microsoft Graph does not support this request (\(status))")
    }
    if status == 401 || status == 403 { return .unauthenticated }
    if (500..<600).contains(status) || status == 423 { return .unavailable("Microsoft Graph answered \(status)\(describe(codes))") }
    return .underlying("Microsoft Graph answered \(status)\(describe(codes))")
  }

  static func retryAfter(in headers: [String: String], now: Date) -> Duration? {
    if let seconds = NetworkError.retryAfter(in: headers) { return seconds }
    guard let value = headers["retry-after"], let date = TrustedClock.parseHTTPDate(value.trimmingCharacters(in: .whitespaces)) else { return nil }
    return .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up))))
  }

  private static func describe(_ codes: [String]) -> String {
    codes.first.map { " (\($0))" } ?? ""
  }

  private func send(_ request: URLRequest, token: OAuthAccessToken) async throws(StorageError) -> GraphResponse {
    var request = request
    request.setValue(token.authorizationHeaderValue, forHTTPHeaderField: "Authorization")
    return try await exchange(request)
  }

  private func exchange(_ request: URLRequest) async throws(StorageError) -> GraphResponse {
    do {
      let (data, response) = try await transport.send(request)
      return GraphResponse(status: response.statusCode, headers: response.lowercasedHeaderFields, body: data)
    } catch {
      throw Self.transportFailure(error)
    }
  }

  private static func transportFailure(_ error: any Error) -> StorageError {
    switch error {
    case is CancellationError, NetworkError.cancelled: return .unavailable("the request was cancelled")
    case let error as URLError: return urlFailure(error)
    case NetworkError.transport(let error): return urlFailure(error)
    default: return .unavailable("the request failed")
    }
  }

  private static func urlFailure(_ error: URLError) -> StorageError {
    error.code == .cancelled ? .unavailable("the request was cancelled") : .unavailable("network error \(error.code.rawValue)")
  }

  private static func converting<Value>(_ body: () async throws(OAuthError) -> Value) async throws(StorageError) -> Value {
    do {
      return try await body()
    } catch {
      switch error {
      case .rateLimited(let retryAfter): throw .rateLimited(retryAfter: retryAfter)
      case .serviceUnavailable, .transport, .cancelled, .malformedTokenResponse: throw .unavailable("Microsoft sign-in: \(error.code)")
      case .tokenStorage: throw .underlying("Microsoft sign-in: \(error.code)")
      default: throw .unauthenticated
      }
    }
  }
}
