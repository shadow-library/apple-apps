import Foundation
import ShadowKeychain
import ShadowNetworking
import ShadowSyncRuntime
import ShadowSyncS3
import ShadowTestSupport
import Testing

@Suite("Sync credential stores", TestTimeLimit.quick)
struct SyncCredentialStoreTests {
  private static let secret = "SECRET-wJalrXUtnFEMI-K7MDENG"
  private static let sessionToken = "SESSION-FwoGZXIvYXdzE"
  private static let accessToken = "ACCESS-eyJ0eXAiOiJKV1Qi"
  private static let refreshToken = "REFRESH-M.R3_BAY.CbN"

  private static func s3Settings(bucket: String = "vaults") throws -> SyncS3Settings {
    SyncS3Settings(try S3Configuration(endpoint: try #require(URL(string: "https://s3.example.com")), region: "eu-west-1", bucket: bucket))
  }

  private static func tokens() -> OAuthTokens {
    OAuthTokens(
      accessToken: accessToken, issuedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: Date(timeIntervalSince1970: 1_700_003_600), refreshToken: refreshToken,
      scopes: ["Files.ReadWrite.AppFolder", "offline_access"])
  }

  private static func expectNoSecret(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
    for secret in [secret, sessionToken, accessToken, refreshToken] {
      #expect(!text.contains(secret), "\(text) shows a secret", sourceLocation: sourceLocation)
    }
  }

  @Test("should round-trip S3 credentials per location and remove them")
  func s3RoundTrips() throws {
    let keychain = InMemoryKeychain()
    let store = RuntimeFixture.stores(keychain.device("phone")).s3Credentials
    let settings = try Self.s3Settings()
    let other = try Self.s3Settings(bucket: "other")
    let credentials = try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: Self.secret, sessionToken: Self.sessionToken)

    try store.save(credentials, for: settings)

    #expect(try store.load(for: settings) == credentials)
    #expect(try store.load(for: other) == nil)
    try store.remove(for: settings)
    #expect(try store.load(for: settings) == nil)
  }

  @Test("should keep S3 credentials in the synced scope so other devices receive them")
  func s3Syncs() throws {
    let keychain = InMemoryKeychain()
    let settings = try Self.s3Settings()
    let credentials = try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: Self.secret)
    try RuntimeFixture.stores(keychain.device("phone")).s3Credentials.save(credentials, for: settings)
    let tablet = RuntimeFixture.stores(keychain.device("tablet")).s3Credentials
    #expect(try tablet.load(for: settings) == nil)

    keychain.deliver()

    #expect(try tablet.load(for: settings) == credentials)
  }

  @Test("should name the S3 item by a digest of the location, never by a secret")
  func s3ItemName() throws {
    let keychain = InMemoryKeychain()
    let device = keychain.device("phone")
    let settings = try Self.s3Settings()
    try RuntimeFixture.stores(device).s3Credentials.save(try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: Self.secret), for: settings)

    let names = try device.store(service: "com.shadow.apps.test.sync.credentials", scope: .synced).allKeys()

    #expect(names == [S3CredentialStore.itemName(for: settings)])
    #expect(names.allSatisfy { $0.hasPrefix("s3-credentials/") && !$0.contains("vaults") })
  }

  @Test("should report unreadable S3 credentials without showing what was stored")
  func s3Unreadable() throws {
    let raw = InMemorySecureStore()
    let settings = try Self.s3Settings()
    try raw.setData(Data(#"{"accessKeyID":"has space","secretAccessKey":"\#(Self.secret)"}"#.utf8), forKey: S3CredentialStore.itemName(for: settings))

    let error = try #require(throws: SyncCredentialError.self) { try S3CredentialStore(store: raw).load(for: settings) }

    #expect(error == .unreadable)
    Self.expectNoSecret(String(describing: error) + (error.errorDescription ?? ""))
  }

  @Test("should report a locked keychain for S3 credentials")
  func s3Locked() throws {
    let store = S3CredentialStore(store: LockedSecureStore())

    #expect(throws: SyncCredentialError.deviceLocked) { try store.load(for: try Self.s3Settings()) }
  }

  @Test("should report a keychain that refuses the build when S3 credentials are saved")
  func s3KeychainRefused() throws {
    let store = S3CredentialStore(store: MissingEntitlementSecureStore())
    let settings = try Self.s3Settings()

    #expect(throws: SyncCredentialError.keychainUnavailable) { try store.save(try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: Self.secret), for: settings) }
    #expect(try store.load(for: settings) == nil)
  }

  @Test("should round-trip OAuth tokens and clear them")
  func oauthRoundTrips() async throws {
    let keychain = InMemoryKeychain()
    let store = RuntimeFixture.stores(keychain.device("phone")).oauthTokens(kind: .oneDrive, clientID: "client-one")

    #expect(try await store.load() == nil)
    try await store.save(Self.tokens())
    #expect(try await store.load() == Self.tokens())
    try await store.clear()
    #expect(try await store.load() == nil)
  }

  @Test("should keep OAuth tokens on this device only")
  func oauthStaysOnDevice() async throws {
    let keychain = InMemoryKeychain()
    try await RuntimeFixture.stores(keychain.device("phone")).oauthTokens(kind: .oneDrive, clientID: "client-one").save(Self.tokens())

    keychain.deliver()

    #expect(try await RuntimeFixture.stores(keychain.device("tablet")).oauthTokens(kind: .oneDrive, clientID: "client-one").load() == nil)
  }

  @Test("should map keychain and decoding failures to token storage errors without the stored bytes")
  func oauthFailures() async throws {
    let raw = InMemorySecureStore()
    let item = KeychainOAuthTokenStore.itemName(kind: .googleDrive, clientID: "client-two")
    try raw.setData(Data(#"{"accessToken":"\#(Self.accessToken)"}"#.utf8), forKey: item)

    let unreadable = try await #require(throws: OAuthError.self) { try await KeychainOAuthTokenStore(store: raw, item: item).load() }
    let locked = try await #require(throws: OAuthError.self) { try await KeychainOAuthTokenStore(store: LockedSecureStore(), item: item).load() }

    #expect(unreadable == .tokenStorage("the stored tokens are unreadable"))
    #expect(locked == .tokenStorage("secure_store.unexpected_status -25308"))
    Self.expectNoSecret(String(describing: unreadable) + (unreadable.errorDescription ?? ""))
  }

  @Test("should show no secret in any description of the stores")
  func descriptionsHideSecrets() async throws {
    let keychain = InMemoryKeychain()
    let stores = RuntimeFixture.stores(keychain.device("phone"))
    let settings = try Self.s3Settings()
    try stores.s3Credentials.save(try S3Credentials(accessKeyID: "AKIAEXAMPLE", secretAccessKey: Self.secret, sessionToken: Self.sessionToken), for: settings)
    let tokens = stores.oauthTokens(kind: .oneDrive, clientID: "client-one")
    try await tokens.save(Self.tokens())

    for subject in [stores as Any, stores.s3Credentials, tokens] {
      var dumped = ""
      dump(subject, to: &dumped)
      Self.expectNoSecret(String(describing: subject) + String(reflecting: subject) + dumped)
    }
  }

  @Test("should lay out the real keychain stores by scope and access group")
  func keychainLayout() throws {
    let stores = SyncSecureStores.keychain(app: "com.shadow.apps.test", sharedAccessGroup: "TEAM.com.shadow.apps.shared")
    let ring = try #require(stores.ring as? KeychainStore)
    let credentials = try #require(stores.credentials as? KeychainStore)
    let marker = try #require(stores.marker as? KeychainStore)
    let tokens = try #require(stores.tokens as? KeychainStore)

    #expect(
      [ring.service, credentials.service, marker.service, tokens.service] == [
        "com.shadow.apps.test.sync", "com.shadow.apps.test.sync.credentials", "com.shadow.apps.test.sync.device", "com.shadow.apps.test.sync.tokens",
      ])
    #expect([ring.accessGroup, credentials.accessGroup, marker.accessGroup, tokens.accessGroup] == ["TEAM.com.shadow.apps.shared", "TEAM.com.shadow.apps.shared", nil, nil])
    #expect(isSynced(ring.scope) && isSynced(credentials.scope))
    #expect(!isSynced(marker.scope) && !isSynced(tokens.scope))
  }

  private func isSynced(_ scope: KeychainStore.Scope) -> Bool {
    guard case .synced = scope else { return false }
    return true
  }
}
