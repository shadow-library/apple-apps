import Foundation

public struct OAuthAuthorizationRequest: Sendable {
  public let url: URL
  public let pending: OAuthPendingAuthorization
}

public struct OAuthPendingAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let pkce: OAuthPKCE
  public let state: String
  public let redirectURI: URL

  public var description: String { "OAuthPendingAuthorization(redirectURI: \(redirectURI), pkce: \(pkce), state: <redacted>)" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: ["redirectURI": redirectURI, "pkce": pkce, "state": "<redacted>"], displayStyle: .struct) }

  func authorizationCode(from callback: URL) throws(OAuthError) -> String {
    guard OAuthSyntax.isSameRedirect(callback, redirectURI) else { throw .redirectMismatch }
    let parameters = try Self.parameters(of: callback)
    guard let returnedState = parameters["state"], OAuthSyntax.constantTimeEquals(returnedState, state) else { throw .stateMismatch }
    if let error = parameters["error"] {
      let description = parameters["error_description"].map(OAuthSyntax.providerText)
      if error == "access_denied" { throw .accessDenied(description: description) }
      throw .authorizationFailed(error: OAuthSyntax.providerText(error), description: description)
    }
    guard let code = parameters["code"], !code.isEmpty else { throw .missingAuthorizationCode }
    return code
  }

  private static func parameters(of callback: URL) throws(OAuthError) -> [String: String] {
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
    var parameters: [String: String] = [:]
    for item in items {
      guard let name = formDecoded(item.name) else { throw .invalidCallback("A parameter name is not valid percent-encoding.") }
      guard parameters[name] == nil else { throw .invalidCallback("The parameter \"\(OAuthSyntax.providerText(name))\" appears more than once.") }
      guard let value = formDecoded(item.value ?? "") else { throw .invalidCallback("The parameter \"\(OAuthSyntax.providerText(name))\" is not valid percent-encoding.") }
      parameters[name] = value
    }
    return parameters
  }

  private static func formDecoded(_ value: String) -> String? {
    value.replacingOccurrences(of: "+", with: "%20").removingPercentEncoding
  }
}
