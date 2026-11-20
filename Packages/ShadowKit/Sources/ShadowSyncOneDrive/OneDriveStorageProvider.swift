import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync

/// Stores a vault as files of one folder, `Apps/<app>/<vault folder>`, named by `OneDriveName`. Listings come from a key index kept from the
/// folder's delta feed and saved in `stateStore`. The transport must not follow redirects (`URLSessionTransport` refuses them by default):
/// downloads are redirected to a pre-authenticated host that must not receive the bearer token.
public struct OneDriveStorageProvider: StorageProvider {
  private static let batchLimit = 20

  public let capabilities: StorageCapabilities

  private let client: GraphClient
  private let paths: OneDrivePaths
  private let vaultFolder: VaultFolderName
  private let options: OneDriveProviderOptions
  private let index: OneDriveIndex

  public init(
    configuration: OneDriveConfiguration, session: OAuthSession, transport: any HTTPTransport, stateStore: any OneDriveStateStore,
    options: OneDriveProviderOptions = OneDriveProviderOptions(), now: @escaping @Sendable () -> Date = { Date() }
  ) throws(StorageError) {
    let options = try options.validated()
    let client = GraphClient(base: OneDriveConfiguration.graphBaseURL, session: session, transport: transport, now: now)
    let paths = OneDrivePaths(vault: configuration.vaultFolder)
    capabilities = StorageCapabilities(
      pushesChangeNotices: false,
      supportsPutIfAbsent: true,
      hasChangeFeed: true,
      reportsServerTime: true,
      maxObjectBytes: options.maxObjectBytes,
      classPolicy: .unrestricted
    )
    self.client = client
    self.paths = paths
    self.options = options
    vaultFolder = configuration.vaultFolder
    index = OneDriveIndex(client: client, paths: paths, store: stateStore, vaultFolder: configuration.vaultFolder, maxPages: options.maxDeltaPagesPerCatchUp)
  }

  /// The first page catches up with the delta feed; later pages read the index as it stands, resuming after the cursor's key.
  public func list(prefix: String, after cursor: ListCursor?) async throws(StorageError) -> ListPage {
    let entries = try await index.entries(catchUp: cursor == nil)
    let remaining = entries.lazy.filter { entry in
      entry.key.hasPrefix(prefix) && cursor.map { $0.token.utf8.lexicographicallyPrecedes(entry.key.rawValue.utf8) } ?? true
    }
    var objects: [StorageObject] = []
    var more = false
    for entry in remaining {
      guard objects.count < options.pageSize else {
        more = true
        break
      }
      objects.append(StorageObject(key: entry.key, size: entry.size))
    }
    return ListPage(objects: objects, next: more ? objects.last.map { ListCursor(token: $0.key.rawValue) } : nil)
  }

  public func get(_ key: ObjectKey) async throws(StorageError) -> Data {
    let name = OneDriveName.encode(key)
    guard let url = client.url(paths.content(name)) else { throw .underlying("the OneDrive download address cannot be built") }
    guard let data = try await OneDriveDownload.fetch(url, client: client) else { throw .notFound(key) }
    guard name.utf8.starts(with: OneDriveName.overflowMarker.utf8) else { return data }
    guard let header = OneDriveKeyHeader.decode(data, name: name), header.key == key else { throw .underlying("the OneDrive file for \(key) does not name its key") }
    return Data(data.dropFirst(header.length))
  }

  public func put(_ key: ObjectKey, data: Data, condition: PutCondition) async throws(StorageError) -> PutReceipt {
    guard data.count <= options.maxObjectBytes else { throw .tooLarge(key, limit: options.maxObjectBytes) }
    let name = OneDriveName.encode(key)
    let body = name.utf8.starts(with: OneDriveName.overflowMarker.utf8) ? OneDriveKeyHeader.encode(key) + data : data
    let upload = OneDriveUpload(client: client, paths: paths, options: options)
    for attempt in 0..<2 {
      switch try await upload.run(key: key, name: name, body: body, condition: condition) {
      case .stored(let serverTime):
        return PutReceipt(serverTime: serverTime)
      case .folderMissing where attempt == 0:
        try await createVaultFolder()
      case .folderMissing:
        break
      }
    }
    throw .unavailable("the OneDrive vault folder could not be created")
  }

  public func delete(_ keys: [ObjectKey]) async throws(StorageError) {
    var seen: Set<String> = []
    let names = keys.map(OneDriveName.encode).filter { seen.insert($0).inserted }
    guard names.count > 1 else {
      if let name = names.first { try await deleteOne(name) }
      return
    }
    for start in stride(from: 0, to: names.count, by: Self.batchLimit) {
      try await deleteBatch(Array(names[start..<min(start + Self.batchLimit, names.count)]))
    }
  }

  public func changeNotices() -> AsyncStream<Void> {
    AsyncStream { _ in }
  }

  private func deleteOne(_ name: String) async throws(StorageError) {
    guard let url = client.url(paths.item(name)) else { throw .underlying("the OneDrive delete address cannot be built") }
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    let response = try await client.authorized(request)
    guard response.isSuccess || response.status == 404 else { throw client.failure(response) }
  }

  private func deleteBatch(_ names: [String]) async throws(StorageError) {
    guard let url = client.url(OneDrivePaths.batch) else { throw .underlying("the Microsoft Graph batch address cannot be built") }
    let requests = names.enumerated().map { GraphBatchRequest.Request(id: "\($0.offset)", method: "DELETE", url: paths.item($0.element)) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONEncoder().encode(GraphBatchRequest(requests: requests))
    } catch {
      throw .underlying("the OneDrive delete batch could not be encoded")
    }
    let response = try await client.authorized(request)
    guard response.isSuccess else { throw client.failure(response) }
    guard let batch = try? JSONDecoder().decode(GraphBatchResponse.self, from: response.body), batch.responses.count == requests.count else {
      throw .unavailable("the OneDrive delete batch answer could not be read")
    }
    let failures = batch.responses.filter { !(200..<300).contains($0.status) && $0.status != 404 }
    let now = client.now()
    let errors = failures.map { GraphClient.failure(status: $0.status, headers: $0.headers, codes: $0.codes, now: now) }
    if let error = errors.first(where: \.isThrottle) ?? errors.first { throw error }
  }

  private func createVaultFolder() async throws(StorageError) {
    guard let url = client.url(OneDrivePaths.appFolderChildren) else { throw .underlying("the OneDrive app folder address cannot be built") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: JSONValue = .object(["name": .string(vaultFolder.rawValue), "folder": .object([:]), "@microsoft.graph.conflictBehavior": .string("fail")])
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      throw .underlying("the OneDrive folder request could not be encoded")
    }
    let response = try await client.authorized(request)
    guard response.isSuccess || response.status == 409 else { throw client.failure(response) }
  }
}

extension StorageError {
  fileprivate var isThrottle: Bool {
    if case .rateLimited = self { return true }
    return false
  }
}
