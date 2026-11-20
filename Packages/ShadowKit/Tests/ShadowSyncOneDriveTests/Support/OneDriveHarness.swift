import Foundation
import ShadowNetworking
import ShadowSync
import ShadowSyncOneDrive
import ShadowTestSupport
import Testing

struct OneDriveHarness {
  static let vault = "Novel Forge"

  let graph: FakeGraph
  let tokens: InMemoryOAuthTokenStore
  let session: OAuthSession
  let state: any OneDriveStateStore
  let configuration: OneDriveConfiguration

  init(graph: FakeGraph = FakeGraph(), state: any OneDriveStateStore = InMemoryOneDriveStateStore(), vault: String = OneDriveHarness.vault) throws {
    let configuration = try OneDriveConfiguration(
      clientID: "00000000-0000-0000-0000-000000000000", redirectURI: #require(URL(string: "msauth.com.shadow.apps.novelforge://auth")),
      vaultFolder: #require(VaultFolderName(vault)))
    let now = Date()
    let tokens = InMemoryOAuthTokenStore(
      tokens: OAuthTokens(
        accessToken: "access-0", issuedAt: now, expiresAt: now.addingTimeInterval(3600), refreshToken: "refresh-0", scopes: OneDriveConfiguration.scopes))
    self.graph = graph
    self.tokens = tokens
    self.state = state
    self.configuration = configuration
    session = OAuthSession(client: OAuthClient(configuration: configuration.oauth, transport: graph), store: tokens)
  }

  func provider(_ options: OneDriveProviderOptions = OneDriveProviderOptions(), state: (any OneDriveStateStore)? = nil) throws -> OneDriveStorageProvider {
    try OneDriveStorageProvider(configuration: configuration, session: session, transport: graph, stateStore: state ?? self.state, options: options)
  }

  var vaultFolderID: String? { graph.folderID(named: configuration.vaultFolder.rawValue) }
}

func key(_ raw: String) throws -> ObjectKey {
  try #require(ObjectKey(raw))
}

func storageError(_ body: () async throws -> Void) async -> StorageError? {
  do {
    try await body()
    return nil
  } catch {
    return error as? StorageError
  }
}
