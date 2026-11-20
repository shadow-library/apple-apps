import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncGoogleDrive
import ShadowTestSupport
import Testing

private enum LiveDrive {
  static let environment = ProcessInfo.processInfo.environment
  static let clientID = environment["SHADOW_GOOGLE_DRIVE_CLIENT_ID"] ?? ""
  static let redirectURI = environment["SHADOW_GOOGLE_DRIVE_REDIRECT_URI"].flatMap(URL.init(string:))
  static let refreshToken = environment["SHADOW_GOOGLE_DRIVE_REFRESH_TOKEN"] ?? ""
  static let vaultPrefix = environment["SHADOW_GOOGLE_DRIVE_VAULT"] ?? ""
  static let isConfigured = !clientID.isEmpty && redirectURI != nil && !refreshToken.isEmpty && !vaultPrefix.isEmpty
}

@Suite("GoogleDriveProvider live", TestTimeLimit.standard)
struct GoogleDriveLiveTests {
  @Test(
    "should satisfy the conformance suite against Google Drive and delete what it wrote",
    .enabled(
      if: LiveDrive.isConfigured,
      "needs SHADOW_GOOGLE_DRIVE_CLIENT_ID, SHADOW_GOOGLE_DRIVE_REDIRECT_URI, SHADOW_GOOGLE_DRIVE_REFRESH_TOKEN and SHADOW_GOOGLE_DRIVE_VAULT"))
  func shouldConformLive() async throws {
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let vault = try #require(VaultFolderName("\(LiveDrive.vaultPrefix.prefix(40))-conformance-\(suffix)"))
    let configuration = try GoogleDriveConfiguration(clientID: LiveDrive.clientID, redirectURI: #require(LiveDrive.redirectURI), vaultFolder: vault)
    let expired = Date(timeIntervalSinceNow: -7200)
    let tokens = OAuthTokens(
      accessToken: "expired", issuedAt: expired, expiresAt: expired.addingTimeInterval(3600), refreshToken: LiveDrive.refreshToken, scopes: [GoogleDriveConfiguration.scope])
    let transport = URLSessionTransport()
    let session = OAuthSession(client: OAuthClient(configuration: configuration.oauth, transport: transport), store: InMemoryOAuthTokenStore(tokens: tokens))
    let provider = GoogleDriveProvider(configuration: configuration, session: session, stateStore: InMemoryGoogleDriveStateStore(), transport: transport)

    let outcome: Result<Void, any Error>
    do {
      try await StorageProviderConformance.verify(consistency: .eventual) { provider }
      outcome = .success(())
    } catch {
      outcome = .failure(error)
    }
    try await provider.delete(provider.listAll(prefix: "").map(\.key))
    #expect(try await provider.listAll(prefix: "").isEmpty)
    try outcome.get()
  }
}
