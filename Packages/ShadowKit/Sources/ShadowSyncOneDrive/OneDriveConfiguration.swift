import Foundation
import ShadowNetworking
import ShadowSync

public struct OneDriveConfiguration: Sendable, Equatable {
  public enum Audience: String, Sendable, Hashable, CaseIterable {
    case common
    case consumers
    case organizations
  }

  public static let scopes = ["Files.ReadWrite.AppFolder", "offline_access"]
  public static let graphBaseURL = url("https://graph.microsoft.com/v1.0")
  private static let authority = url("https://login.microsoftonline.com")

  public let audience: Audience
  public let oauth: OAuthClientConfiguration
  public let vaultFolder: VaultFolderName

  public init(clientID: String, redirectURI: URL, vaultFolder: VaultFolderName, audience: Audience = .common) throws(OAuthError) {
    let endpoints = Self.authority.appending(path: audience.rawValue).appending(path: "oauth2/v2.0")
    oauth = try OAuthClientConfiguration(
      authorizationEndpoint: endpoints.appending(path: "authorize"),
      tokenEndpoint: endpoints.appending(path: "token"),
      clientID: clientID,
      redirectURI: redirectURI,
      scopes: Self.scopes,
      additionalAuthorizationParameters: ["prompt": "select_account"],
      sendsScopeInTokenRequests: true
    )
    self.audience = audience
    self.vaultFolder = vaultFolder
  }

  private static func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("The Microsoft address literal \(string) is not a URL.") }
    return url
  }
}
