import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncGoogleDrive
import Testing

@Suite("GoogleDriveConfiguration", TestTimeLimit.quick)
struct GoogleDriveConfigurationTests {
  private static let redirect = URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect")

  private static func make(clientID: String = "1234-abcd.apps.googleusercontent.com", redirect: URL? = redirect) throws -> GoogleDriveConfiguration {
    try GoogleDriveConfiguration(clientID: clientID, redirectURI: #require(redirect), vaultFolder: #require(VaultFolderName("Novel Forge")))
  }

  @Test("should sign in to Google for the app data folder only, asking for offline access")
  func usesGoogleEndpoints() throws {
    let configuration = try Self.make()

    #expect(configuration.oauth.authorizationEndpoint.absoluteString == "https://accounts.google.com/o/oauth2/v2/auth")
    #expect(configuration.oauth.tokenEndpoint.absoluteString == "https://oauth2.googleapis.com/token")
    #expect(configuration.oauth.scopes == ["https://www.googleapis.com/auth/drive.appdata"])
    #expect(configuration.oauth.additionalAuthorizationParameters == ["access_type": "offline"])
    #expect(configuration.oauth.sendsScopeInTokenRequests == false)
    #expect(configuration.oauth.redirectURI == Self.redirect)
    #expect(configuration.vaultFolder.rawValue == "Novel Forge")
    #expect(GoogleDriveConfiguration.apiBaseURL.absoluteString == "https://www.googleapis.com/drive/v3")
    #expect(GoogleDriveConfiguration.uploadBaseURL.absoluteString == "https://www.googleapis.com/upload/drive/v3")
  }

  @Test("should take the client id and redirect from the app and refuse invalid ones")
  func validatesClient() {
    #expect(throws: OAuthError.self) { try Self.make(clientID: "") }
    #expect(throws: OAuthError.self) { try Self.make(redirect: URL(string: "googleapp:/oauth2redirect")) }
  }
}
