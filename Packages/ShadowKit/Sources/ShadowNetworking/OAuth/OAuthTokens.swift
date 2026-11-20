import Foundation

public struct OAuthTokens: Sendable, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let accessToken: String
  public let tokenType: String
  public let issuedAt: Date
  public let expiresAt: Date?
  public let refreshToken: String?
  public let scopes: [String]

  public init(accessToken: String, tokenType: String = "Bearer", issuedAt: Date, expiresAt: Date?, refreshToken: String?, scopes: [String]) {
    self.accessToken = accessToken
    self.tokenType = tokenType
    self.issuedAt = issuedAt
    self.expiresAt = expiresAt
    self.refreshToken = refreshToken
    self.scopes = scopes
  }

  public var description: String {
    let expiry = expiresAt.map { "\($0)" } ?? "unknown"
    let refresh = refreshToken == nil ? "none" : "<redacted>"
    return "OAuthTokens(tokenType: \(tokenType), issuedAt: \(issuedAt), expiresAt: \(expiry), scopes: \(scopes), accessToken: <redacted>, refreshToken: \(refresh))"
  }

  public var debugDescription: String { description }

  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "accessToken": "<redacted>", "tokenType": tokenType, "issuedAt": issuedAt, "expiresAt": expiresAt as Any,
        "refreshToken": refreshToken == nil ? "none" : "<redacted>", "scopes": scopes,
      ],
      displayStyle: .struct
    )
  }

  public var accessCredential: OAuthAccessToken { OAuthAccessToken(value: accessToken, expiresAt: expiresAt) }

  func refreshDue(at now: Date, margin: Duration) -> Bool {
    guard let expiresAt else { return false }
    let lifetime = max(expiresAt.timeIntervalSince(issuedAt), 0)
    let seconds = Double(margin.components.seconds) + Double(margin.components.attoseconds) / 1e18
    return now >= expiresAt.addingTimeInterval(-min(seconds, lifetime / 2))
  }
}

public struct OAuthAccessToken: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let value: String
  public let expiresAt: Date?

  public var authorizationHeaderValue: String { "Bearer \(value)" }

  public var description: String { "OAuthAccessToken(expiresAt: \(expiresAt.map { "\($0)" } ?? "unknown"), value: <redacted>)" }

  public var debugDescription: String { description }

  public var customMirror: Mirror { Mirror(self, children: ["expiresAt": expiresAt as Any, "value": "<redacted>"], displayStyle: .struct) }
}
