import Foundation
import ShadowCore

public struct OAuthClient: Sendable {
  static let stateByteCount = 32
  private static let reauthorizationErrors: Set<String> = ["invalid_grant", "interaction_required"]

  public let configuration: OAuthClientConfiguration
  let now: @Sendable () -> Date
  private let transport: any HTTPTransport
  private let random: OAuthRandomSource

  public init(configuration: OAuthClientConfiguration, transport: any HTTPTransport, random: OAuthRandomSource = .system, now: @escaping @Sendable () -> Date = { Date() }) {
    self.configuration = configuration
    self.transport = transport
    self.random = random
    self.now = now
  }

  public func beginAuthorization() throws(OAuthError) -> OAuthAuthorizationRequest {
    let pending = OAuthPendingAuthorization(pkce: .generate(using: random), state: random.token(byteCount: Self.stateByteCount), redirectURI: configuration.redirectURI)
    guard var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
      throw .invalidConfiguration("The authorization endpoint cannot be parsed.")
    }
    var parameters = [
      ("response_type", "code"),
      ("client_id", configuration.clientID),
      ("redirect_uri", configuration.redirectURI.absoluteString),
    ]
    if !configuration.scopes.isEmpty { parameters.append(("scope", configuration.scopes.joined(separator: " "))) }
    parameters += [("state", pending.state), ("code_challenge", pending.pkce.challenge), ("code_challenge_method", OAuthPKCE.method)]
    parameters += configuration.additionalAuthorizationParameters.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    let encoded = parameters.map { URLQueryItem(name: OAuthSyntax.percentEncoded($0.0), value: OAuthSyntax.percentEncoded($0.1)) }
    components.percentEncodedQueryItems = (components.percentEncodedQueryItems ?? []) + encoded
    guard let url = components.url else { throw .invalidConfiguration("The authorization address cannot be built.") }
    return OAuthAuthorizationRequest(url: url, pending: pending)
  }

  public func completeAuthorization(callback: URL, pending: OAuthPendingAuthorization) async throws(OAuthError) -> OAuthTokens {
    let code = try pending.authorizationCode(from: callback)
    var form = [
      ("grant_type", "authorization_code"),
      ("code", code),
      ("redirect_uri", pending.redirectURI.absoluteString),
      ("client_id", configuration.clientID),
      ("code_verifier", pending.pkce.verifier),
    ]
    if configuration.sendsScopeInTokenRequests, !configuration.scopes.isEmpty { form.append(("scope", configuration.scopes.joined(separator: " "))) }
    return try await requestTokens(form, previous: nil)
  }

  public func refresh(_ tokens: OAuthTokens) async throws(OAuthError) -> OAuthTokens {
    guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else { throw .reauthorizationRequired }
    var form = [("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", configuration.clientID)]
    if configuration.sendsScopeInTokenRequests, !configuration.scopes.isEmpty { form.append(("scope", configuration.scopes.joined(separator: " "))) }
    return try await requestTokens(form, previous: tokens)
  }

  private func requestTokens(_ form: [(String, String)], previous: OAuthTokens?) async throws(OAuthError) -> OAuthTokens {
    var request = URLRequest(url: configuration.tokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = OAuthSyntax.formEncoded(form)
    let issuedAt = now()
    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await transport.send(request)
    } catch {
      throw Self.converting(error)
    }
    let body = try? JSONDecoder().decode(TokenResponse.self, from: data)
    if let error = body?.error { throw failure(status: response, error: OAuthSyntax.providerText(error), description: body?.errorDescription.map(OAuthSyntax.providerText)) }
    guard (200..<300).contains(response.statusCode) else { throw failure(status: response, error: nil, description: nil) }
    guard let body else { throw .malformedTokenResponse("The body is not a JSON token response.") }
    return try body.tokens(issuedAt: issuedAt, previous: previous, requestedScopes: configuration.scopes)
  }

  private func failure(status response: HTTPURLResponse, error: String?, description: String?) -> OAuthError {
    let status = response.statusCode
    if let error, Self.reauthorizationErrors.contains(error) { return .reauthorizationRequired }
    if status == 429 { return .rateLimited(retryAfter: retryAfter(response)) }
    if (500..<600).contains(status) { return .serviceUnavailable(status: status, retryAfter: retryAfter(response)) }
    return .tokenRequestRejected(status: status, error: error, description: description)
  }

  private func retryAfter(_ response: HTTPURLResponse) -> Duration? {
    let headers = response.lowercasedHeaderFields
    if let seconds = NetworkError.retryAfter(in: headers) { return seconds }
    guard let value = headers["retry-after"], let date = TrustedClock.parseHTTPDate(value.trimmingCharacters(in: .whitespaces)) else { return nil }
    return .seconds(max(0, Int(date.timeIntervalSince(now()).rounded(.up))))
  }

  private static func converting(_ error: any Error) -> OAuthError {
    switch error {
    case is CancellationError: return .cancelled
    case let error as URLError: return error.code == .cancelled ? .cancelled : .transport(error)
    case NetworkError.cancelled: return .cancelled
    case NetworkError.transport(let error): return error.code == .cancelled ? .cancelled : .transport(error)
    default: return .underlying(String(describing: error))
    }
  }
}

private struct TokenResponse: Decodable {
  let accessToken: String?
  let tokenType: String?
  let expiresIn: Lifetime?
  let refreshToken: String?
  let scope: String?
  let error: String?
  let errorDescription: String?

  enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case tokenType = "token_type"
    case expiresIn = "expires_in"
    case refreshToken = "refresh_token"
    case scope
    case error
    case errorDescription = "error_description"
  }

  func tokens(issuedAt: Date, previous: OAuthTokens?, requestedScopes: [String]) throws(OAuthError) -> OAuthTokens {
    guard let accessToken, !accessToken.isEmpty else { throw .malformedTokenResponse("The response has no access token.") }
    guard let tokenType else { throw .malformedTokenResponse("The response has no token type.") }
    guard tokenType.lowercased() == "bearer" else { throw .unsupportedTokenType(OAuthSyntax.providerText(tokenType)) }
    if case .invalid = expiresIn { throw .malformedTokenResponse("The token lifetime is not a non-negative number of seconds.") }
    let expiresAt = expiresIn?.seconds.map { issuedAt.addingTimeInterval($0) }
    let refreshed = refreshToken.flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken
    let granted = scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? requestedScopes
    return OAuthTokens(accessToken: accessToken, tokenType: "Bearer", issuedAt: issuedAt, expiresAt: expiresAt, refreshToken: refreshed, scopes: granted)
  }
}

private enum Lifetime: Decodable {
  case valid(TimeInterval)
  case invalid

  var seconds: TimeInterval? {
    guard case .valid(let seconds) = self else { return nil }
    return seconds
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let number = (try? container.decode(Double.self)) ?? (try? container.decode(String.self)).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard let number, number.isFinite, number >= 0 else {
      self = .invalid
      return
    }
    self = .valid(number)
  }
}
