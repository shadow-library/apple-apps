import Foundation
import ShadowNetworking
import ShadowSync

public struct GoogleDriveConfiguration: Sendable, Equatable {
  public static let scope = "https://www.googleapis.com/auth/drive.appdata"
  public static let authorizationEndpoint = url("https://accounts.google.com/o/oauth2/v2/auth")
  public static let tokenEndpoint = url("https://oauth2.googleapis.com/token")
  public static let apiBaseURL = url("https://www.googleapis.com/drive/v3")
  public static let uploadBaseURL = url("https://www.googleapis.com/upload/drive/v3")

  public let oauth: OAuthClientConfiguration
  public let vaultFolder: VaultFolderName

  public init(clientID: String, redirectURI: URL, vaultFolder: VaultFolderName) throws(OAuthError) {
    oauth = try OAuthClientConfiguration(
      authorizationEndpoint: Self.authorizationEndpoint,
      tokenEndpoint: Self.tokenEndpoint,
      clientID: clientID,
      redirectURI: redirectURI,
      scopes: [Self.scope],
      additionalAuthorizationParameters: ["access_type": "offline"]
    )
    self.vaultFolder = vaultFolder
  }

  private static func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("The Google address literal \(string) is not a URL.") }
    return url
  }
}
