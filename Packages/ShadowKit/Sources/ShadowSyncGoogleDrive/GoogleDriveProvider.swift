import Foundation
import ShadowNetworking
import ShadowSync

/// Stores a vault as flat files in the app data folder. Drive names are not unique, so each file carries the vault in its app properties and the key as its name,
/// and the provider addresses files by id through an index kept from the changes feed. When several files hold one key, the most recently modified wins
/// (ties go to the smallest file id); an overwrite updates that file and then deletes the others.
/// The transport must refuse redirects (as `URLSessionTransport` does by default) so a redirected download never carries the bearer to another host.
public final class GoogleDriveProvider: StorageProvider {
  public let capabilities: StorageCapabilities

  private let client: GoogleDriveClient
  private let index: GoogleDriveIndex
  private let tuning: GoogleDriveTuning

  public convenience init(
    configuration: GoogleDriveConfiguration, session: OAuthSession, stateStore: any GoogleDriveStateStore, transport: any HTTPTransport = URLSessionTransport()
  ) {
    self.init(configuration: configuration, session: session, stateStore: stateStore, transport: transport, tuning: GoogleDriveTuning())
  }

  init(configuration: GoogleDriveConfiguration, session: OAuthSession, stateStore: any GoogleDriveStateStore, transport: any HTTPTransport, tuning: GoogleDriveTuning) {
    let tuning = tuning.validated()
    let http = GoogleDriveHTTP(session: session, transport: transport, trustedOrigins: [GoogleDriveConfiguration.apiBaseURL, GoogleDriveConfiguration.uploadBaseURL])
    let client = GoogleDriveClient(
      vault: configuration.vaultFolder.rawValue, http: http, tuning: tuning, apiBaseURL: GoogleDriveConfiguration.apiBaseURL,
      uploadBaseURL: GoogleDriveConfiguration.uploadBaseURL)
    self.client = client
    self.tuning = tuning
    index = GoogleDriveIndex(client: client, store: stateStore, tuning: tuning)
    capabilities = StorageCapabilities(
      pushesChangeNotices: false, supportsPutIfAbsent: false, hasChangeFeed: true, reportsServerTime: true, maxObjectBytes: tuning.maxObjectBytes, classPolicy: .unrestricted)
  }

  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    try await index.page(prefix: prefix, after: cursor)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    var caughtUp = false
    for _ in 0..<tuning.readAttempts {
      guard let file = try await index.winner(of: key) else {
        guard !caughtUp else { throw .notFound(key) }
        caughtUp = true
        try await index.catchUp()
        continue
      }
      if let data = try await client.download(file.id) { return data }
      await index.forget(file.id)
      if !caughtUp {
        caughtUp = true
        try await index.catchUp()
      }
    }
    throw .notFound(key)
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard data.count <= tuning.maxObjectBytes else { throw .tooLarge(key, limit: tuning.maxObjectBytes) }
    if try await index.winner(of: key) == nil { try await index.catchUp() }
    for _ in 0..<tuning.readAttempts {
      guard let current = try await index.winner(of: key) else { break }
      guard condition == .overwrite else { throw .alreadyExists(key) }
      switch try await client.update(current.id, data: data) {
      case .written(let file, let serverTime):
        await index.record(file)
        await deleteLosers(of: key, keeping: file.id)
        return PutReceipt(serverTime: serverTime)
      case .missing:
        await index.forget(current.id)
      }
    }
    let (file, serverTime) = try await client.create(key, data: data)
    await index.record(file)
    return PutReceipt(serverTime: serverTime)
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    guard !keys.isEmpty else { return }
    try await index.catchUp()
    for key in keys {
      for file in try await index.candidates(of: key) {
        try await client.delete(file.id)
        await index.forget(file.id)
      }
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  /// Best effort: a loser left behind is never read, because the file just written is now the most recently modified.
  private func deleteLosers(of key: ObjectKey, keeping winner: String) async {
    guard let losers = try? await index.candidates(of: key).filter({ $0.id != winner }) else { return }
    for loser in losers {
      guard (try? await client.delete(loser.id)) != nil else { continue }
      await index.forget(loser.id)
    }
  }
}
