import Foundation

public struct OAuthClientConfiguration: Sendable, Equatable {
  static let reservedAuthorizationParameters: Set<String> = [
    "response_type", "client_id", "redirect_uri", "scope", "state", "code_challenge", "code_challenge_method",
  ]

  public let authorizationEndpoint: URL
  public let tokenEndpoint: URL
  public let clientID: String
  public let redirectURI: URL
  public let scopes: [String]
  public let additionalAuthorizationParameters: [String: String]
  public let sendsScopeInTokenRequests: Bool

  public init(
    authorizationEndpoint: URL,
    tokenEndpoint: URL,
    clientID: String,
    redirectURI: URL,
    scopes: [String],
    additionalAuthorizationParameters: [String: String] = [:],
    sendsScopeInTokenRequests: Bool = false
  ) throws(OAuthError) {
    try Self.validateEndpoint(authorizationEndpoint, name: "authorization endpoint")
    try Self.validateEndpoint(tokenEndpoint, name: "token endpoint")
    guard OAuthSyntax.isVisibleASCII(clientID) else { throw .invalidConfiguration("The client id must be printable ASCII.") }
    try Self.validateRedirect(redirectURI)
    guard scopes.allSatisfy(OAuthSyntax.isScopeToken) else { throw .invalidConfiguration("A scope must be non-empty and hold no spaces, quotes or backslashes.") }
    guard Set(scopes).count == scopes.count else { throw .invalidConfiguration("A scope is listed twice.") }
    let endpointParameters = Set(URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? [])
    guard endpointParameters.isDisjoint(with: Self.reservedAuthorizationParameters) else {
      throw .invalidConfiguration("The authorization endpoint already carries a parameter the request sets.")
    }
    for name in additionalAuthorizationParameters.keys {
      guard !name.isEmpty, !Self.reservedAuthorizationParameters.contains(name), !endpointParameters.contains(name) else {
        throw .invalidConfiguration("The authorization parameter \"\(name)\" is empty, reserved or already on the endpoint.")
      }
    }
    self.authorizationEndpoint = authorizationEndpoint
    self.tokenEndpoint = tokenEndpoint
    self.clientID = clientID
    self.redirectURI = redirectURI
    self.scopes = scopes
    self.additionalAuthorizationParameters = additionalAuthorizationParameters
    self.sendsScopeInTokenRequests = sendsScopeInTokenRequests
  }

  private static func validateEndpoint(_ url: URL, name: String) throws(OAuthError) {
    guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { throw .invalidConfiguration("The \(name) must be https.") }
    guard url.user() == nil, url.password() == nil, url.fragment() == nil else { throw .invalidConfiguration("The \(name) must carry no credentials or fragment.") }
  }

  private static func validateRedirect(_ url: URL) throws(OAuthError) {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { throw .invalidConfiguration("The redirect URI needs a scheme.") }
    guard url.user() == nil, url.password() == nil, url.query() == nil, url.fragment() == nil else {
      throw .invalidConfiguration("The redirect URI must carry no credentials, query or fragment.")
    }
    switch scheme {
    case "https":
      guard let host = url.host(), !host.isEmpty else { throw .invalidConfiguration("An https redirect URI needs a host.") }
    case "http":
      guard OAuthSyntax.isLoopback(url) else { throw .invalidConfiguration("An http redirect URI must be a loopback address.") }
    default:
      guard scheme.contains(".") else { throw .invalidConfiguration("A private-use redirect scheme must be a reverse domain name.") }
    }
  }
}
