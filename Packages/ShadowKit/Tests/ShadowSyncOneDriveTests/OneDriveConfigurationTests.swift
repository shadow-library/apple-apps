import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncOneDrive
import Testing

@Suite("OneDriveConfiguration", TestTimeLimit.quick)
struct OneDriveConfigurationTests {
  private static let redirect = URL(string: "msauth.com.shadow.apps.novelforge://auth")

  private static func make(clientID: String = "00000000-0000-0000-0000-000000000000", redirect: URL? = redirect, audience: OneDriveConfiguration.Audience = .common) throws
    -> OneDriveConfiguration
  {
    try OneDriveConfiguration(clientID: clientID, redirectURI: #require(redirect), vaultFolder: #require(VaultFolderName("Novel Forge")), audience: audience)
  }

  @Test("should sign in through the common Microsoft identity platform v2 endpoints for the app folder")
  func usesCommonAuthority() throws {
    let configuration = try Self.make()

    #expect(configuration.oauth.authorizationEndpoint.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
    #expect(configuration.oauth.tokenEndpoint.absoluteString == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
    #expect(configuration.oauth.scopes == ["Files.ReadWrite.AppFolder", "offline_access"])
    #expect(configuration.oauth.sendsScopeInTokenRequests)
    #expect(configuration.oauth.additionalAuthorizationParameters == ["prompt": "select_account"])
    #expect(configuration.oauth.clientID == "00000000-0000-0000-0000-000000000000")
    #expect(configuration.vaultFolder.rawValue == "Novel Forge")
    #expect(OneDriveConfiguration.graphBaseURL.absoluteString == "https://graph.microsoft.com/v1.0")
  }

  @Test("should narrow the authority to the chosen audience", arguments: OneDriveConfiguration.Audience.allCases)
  func usesAudience(audience: OneDriveConfiguration.Audience) throws {
    let configuration = try Self.make(audience: audience)

    #expect(configuration.oauth.authorizationEndpoint.path() == "/\(audience.rawValue)/oauth2/v2.0/authorize")
    #expect(configuration.oauth.tokenEndpoint.path() == "/\(audience.rawValue)/oauth2/v2.0/token")
  }

  @Test("should take the client id and redirect from the app and refuse invalid ones")
  func validatesClient() {
    #expect(throws: OAuthError.self) { try Self.make(clientID: "") }
    #expect(throws: OAuthError.self) { try Self.make(redirect: URL(string: "http://example.com/callback")) }
  }
}
