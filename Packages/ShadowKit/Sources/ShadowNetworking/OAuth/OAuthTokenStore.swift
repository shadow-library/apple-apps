import Foundation

public protocol OAuthTokenStore: Sendable {
  func load() async throws(OAuthError) -> OAuthTokens?
  func save(_ tokens: OAuthTokens) async throws(OAuthError)
  func clear() async throws(OAuthError)
}
