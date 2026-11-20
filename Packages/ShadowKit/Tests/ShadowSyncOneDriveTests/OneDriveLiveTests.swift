import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncOneDrive
import ShadowTestSupport
import Testing

private struct OneDriveLiveSettings {
  let clientID: String
  let redirectURI: URL
  let refreshToken: String
  let vaultFolder: String
  let audience: OneDriveConfiguration.Audience

  static let current: OneDriveLiveSettings? = {
    let environment = ProcessInfo.processInfo.environment
    guard let clientID = environment["SHADOW_ONEDRIVE_LIVE_CLIENT_ID"], let redirect = environment["SHADOW_ONEDRIVE_LIVE_REDIRECT_URI"].flatMap(URL.init(string:)),
      let refreshToken = environment["SHADOW_ONEDRIVE_LIVE_REFRESH_TOKEN"], let vaultFolder = environment["SHADOW_ONEDRIVE_LIVE_VAULT_FOLDER"]
    else { return nil }
    let audience = environment["SHADOW_ONEDRIVE_LIVE_AUDIENCE"].flatMap(OneDriveConfiguration.Audience.init(rawValue:)) ?? .common
    return OneDriveLiveSettings(clientID: clientID, redirectURI: redirect, refreshToken: refreshToken, vaultFolder: vaultFolder, audience: audience)
  }()
}

@Suite("OneDriveStorageProvider live", TestTimeLimit.standard, .enabled(if: OneDriveLiveSettings.current != nil, "needs the SHADOW_ONEDRIVE_LIVE_* variables"))
struct OneDriveLiveTests {
  @Test("should satisfy the eventual conformance suite in a fresh vault folder of a real OneDrive app folder")
  func conformsLive() async throws {
    let settings = try #require(OneDriveLiveSettings.current)
    let vault = try #require(VaultFolderName("\(settings.vaultFolder.prefix(40)) \(UUID().uuidString.prefix(8).lowercased())"))
    let configuration = try OneDriveConfiguration(clientID: settings.clientID, redirectURI: settings.redirectURI, vaultFolder: vault, audience: settings.audience)
    let transport = URLSessionTransport()
    let tokens = InMemoryOAuthTokenStore(
      tokens: OAuthTokens(accessToken: "", issuedAt: .distantPast, expiresAt: .distantPast, refreshToken: settings.refreshToken, scopes: OneDriveConfiguration.scopes))
    let session = OAuthSession(client: OAuthClient(configuration: configuration.oauth, transport: transport), store: tokens)
    let provider = try OneDriveStorageProvider(configuration: configuration, session: session, transport: transport, stateStore: InMemoryOneDriveStateStore())
    var failure: (any Error)?
    do {
      try await StorageProviderConformance.verify(consistency: .eventual) { provider }
    } catch {
      failure = error
    }
    try await Self.removeVaultFolder(vault, session: session, transport: transport)
    if let failure { throw failure }
  }

  private static func removeVaultFolder(_ vault: VaultFolderName, session: OAuthSession, transport: any HTTPTransport) async throws {
    let escaped = try #require(vault.rawValue.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
    var request = URLRequest(url: try #require(URL(string: OneDriveConfiguration.graphBaseURL.absoluteString + "/me/drive/special/approot:/" + escaped)))
    request.httpMethod = "DELETE"
    request.setValue(try await session.accessToken().authorizationHeaderValue, forHTTPHeaderField: "Authorization")
    let (_, response) = try await transport.send(request)
    #expect([204, 404].contains(response.statusCode))
  }
}
