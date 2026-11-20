import Foundation
import ShadowNetworking
import ShadowSync
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSyncGoogleDrive

enum DriveFixture {
  static let vault = "Novel Forge"

  static func configuration(vault: String = vault) throws -> GoogleDriveConfiguration {
    try GoogleDriveConfiguration(
      clientID: "1234-abcd.apps.googleusercontent.com", redirectURI: #require(URL(string: "com.googleusercontent.apps.1234-abcd:/oauth2redirect")),
      vaultFolder: #require(VaultFolderName(vault)))
  }

  static func session(_ fake: FakeGoogleDrive, configuration: GoogleDriveConfiguration) -> OAuthSession {
    let now = Date()
    let tokens = OAuthTokens(
      accessToken: FakeGoogleDrive.initialAccessToken, issuedAt: now, expiresAt: now.addingTimeInterval(3600), refreshToken: "refresh-0",
      scopes: [GoogleDriveConfiguration.scope])
    return OAuthSession(client: OAuthClient(configuration: configuration.oauth, transport: fake), store: InMemoryOAuthTokenStore(tokens: tokens))
  }

  static func provider(
    _ fake: FakeGoogleDrive, vault: String = vault, store: any GoogleDriveStateStore = InMemoryGoogleDriveStateStore(), tuning: GoogleDriveTuning = GoogleDriveTuning()
  ) throws -> GoogleDriveProvider {
    let configuration = try configuration(vault: vault)
    return GoogleDriveProvider(configuration: configuration, session: session(fake, configuration: configuration), stateStore: store, transport: fake, tuning: tuning)
  }

  static func key(_ raw: String) throws -> ObjectKey {
    try #require(ObjectKey(raw))
  }

  static func bytes(_ count: Int, salt: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) &+ salt })
  }

  static func error(_ body: () async throws -> Void) async -> StorageError? {
    do {
      try await body()
      return nil
    } catch let error as StorageError {
      return error
    } catch {
      return .underlying("not a storage error: \(error)")
    }
  }
}

final class DriveClock: Sendable {
  private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

  var now: Date { current.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    current.withLock { $0 = $0.addingTimeInterval(seconds) }
  }

  func tuning(_ base: GoogleDriveTuning = GoogleDriveTuning()) -> GoogleDriveTuning {
    var tuning = base
    tuning.now = { self.now }
    return tuning
  }
}
