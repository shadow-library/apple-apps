import Foundation
import ShadowCore
import ShadowNetworking
import ShadowSync
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSyncOneDrive

/// Refuses requests from a cancelled task, as URLSession does, and cancels the calling task when it sees a matching request.
private final class CancellingTransport: HTTPTransport {
  private let inner: FakeGraph
  private let trigger: @Sendable (FakeGraph.Recorded) -> Bool
  private let fired = Mutex(false)

  init(_ inner: FakeGraph, cancelWhen trigger: @escaping @Sendable (FakeGraph.Recorded) -> Bool) {
    self.inner = inner
    self.trigger = trigger
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if Task.isCancelled { throw URLError(.cancelled) }
    guard let url = request.url else { throw URLError(.badURL) }
    let recorded = FakeGraph.Recorded(
      method: request.httpMethod ?? "GET", url: url, authorization: nil, range: nil, contentRange: request.value(forHTTPHeaderField: "Content-Range"), body: Data())
    let shouldCancel =
      trigger(recorded)
      && fired.withLock { fired in
        defer { fired = true }
        return !fired
      }
    guard shouldCancel else { return try await inner.send(request) }
    withUnsafeCurrentTask { $0?.cancel() }
    throw URLError(.cancelled)
  }
}

@Suite("OneDriveStorageProvider failures", TestTimeLimit.standard)
struct OneDriveFailureTests {
  private static let noChangeFeed = StorageError.underlying("OneDrive offers no change feed for the vault folder on this account")

  private static func onDelta(_ recorded: FakeGraph.Recorded) -> Bool {
    recorded.url.host() == FakeGraph.graphHost && recorded.url.path().hasSuffix("/delta")
  }

  @Test(
    "should report a refused delta feed as a lasting failure, never as a sign-in problem",
    arguments: [
      (501, "", noChangeFeed),
      (505, "", noChangeFeed),
      (400, #"{"error":{"code":"invalidRequest"}}"#, noChangeFeed),
      (403, #"{"error":{"code":"accessDenied"}}"#, noChangeFeed),
      (400, #"{"error":{"code":"notSupported"}}"#, noChangeFeed),
      (403, #"{"error":{"code":"activityLimitReached"}}"#, StorageError.rateLimited(retryAfter: nil)),
      (503, "", StorageError.unavailable("Microsoft Graph answered 503")),
    ])
  func mapsRefusedDelta(status: Int, body: String, expected: StorageError) async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").count == 1)
    let deltaBefore = harness.graph.requests.count(where: Self.onDelta)
    for _ in 0..<2 { harness.graph.inject(status: status, body: body, when: Self.onDelta) }
    #expect(await storageError { _ = try await provider.list(prefix: "", after: nil) } == expected)
    #expect(harness.graph.requests.count(where: Self.onDelta) - deltaBefore == (expected == Self.noChangeFeed ? 2 : 1))
    let saved = try #require(await (harness.state as? InMemoryOneDriveStateStore)?.state)
    #expect((saved.folderID == nil && saved.position == nil) == (expected == Self.noChangeFeed))
    #expect(saved.entries.values.map(\.key.rawValue) == ["doc"])
  }

  @Test(
    "should start over from the folder's path once when Graph refuses a saved delta link",
    arguments: [(400, #"{"error":{"code":"invalidRequest"}}"#), (403, #"{"error":{"code":"accessDenied"}}"#)])
  func recoversFromRefusedSavedLink(status: Int, body: String) async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("a"), data: Data([1]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["a"])
    let store = try #require(harness.state as? InMemoryOneDriveStateStore)
    let before = try #require(await store.state?.position)
    _ = try await provider.put(try key("b"), data: Data([2]), condition: .overwrite)
    harness.graph.inject(status: status, body: body) { Self.onDelta($0) && $0.url.query()?.contains("token=") == true }
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["a", "b"])
    let after = try #require(await store.state)
    #expect(after.position != before)
    #expect(after.position.map { if case .caughtUp = $0 { true } else { false } } == true)
    #expect(after.replacement == nil)
    let folderLookups = harness.graph.requests.filter { $0.method == "GET" && $0.url.path(percentEncoded: false).hasSuffix("approot:/\(OneDriveHarness.vault)") }
    #expect(folderLookups.count == 2)
  }

  @Test("should report an unsupported request outside the feed as a lasting failure")
  func mapsNotImplemented() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    harness.graph.inject(status: 501, body: #"{"error":{"code":"notImplemented"}}"#) { $0.method == "PUT" }
    let error = await storageError { _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite) }
    #expect(error == .underlying("Microsoft Graph does not support this request (501)"))
  }

  @Test("should treat a refused download address as unavailable without sending the token there", arguments: [401, 403, 410])
  func refusesExpiredDownloadAddress(status: Int) async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    let doc = try key("doc")
    _ = try await provider.put(doc, data: Data([1]), condition: .overwrite)
    harness.graph.inject(status: status) { $0.url.host() == FakeGraph.downloadHost }
    #expect(await storageError { _ = try await provider.get(doc) } == .unavailable("the OneDrive download address was refused"))
    #expect(try await provider.get(doc) == Data([1]))
    let downloads = harness.graph.requests.filter { $0.url.host() == FakeGraph.downloadHost }
    #expect(downloads.count == 2)
    #expect(downloads.allSatisfy { $0.authorization == nil })
  }

  @Test("should report a download redirect without an address as unavailable")
  func refusesRedirectWithoutLocation() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    let doc = try key("doc")
    _ = try await provider.put(doc, data: Data([1]), condition: .overwrite)
    harness.graph.inject(status: 302) { $0.url.host() == FakeGraph.graphHost && $0.url.absoluteString.hasSuffix(":/content") && $0.method == "GET" }
    #expect(await storageError { _ = try await provider.get(doc) } == .unavailable("OneDrive redirected a download without an address"))
  }

  @Test("should report keyConflict when a folder holds the key's name", arguments: [OneDriveProviderOptions.maximumSimpleUploadBytes, 0])
  func reportsFolderConflict(simpleUploadLimit: Int) async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider(OneDriveProviderOptions(simpleUploadLimit: simpleUploadLimit))
    _ = try await provider.put(try key("seed"), data: Data(), condition: .overwrite)
    let blocked = try key("Blocked/name")
    _ = harness.graph.seedFolder(name: OneDriveName.encode(blocked), in: try #require(harness.vaultFolderID))
    #expect(await storageError { _ = try await provider.put(blocked, data: Data([1, 2]), condition: .overwrite) } == .keyConflict(blocked))
    #expect(harness.graph.openSessions == 0)
  }

  @Test("should empty the index when the vault folder is renamed")
  func emptiesIndexOnRename() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("doc"), data: Data([1]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").count == 1)
    harness.graph.renameItem(named: OneDriveHarness.vault, in: FakeGraph.appFolderID, to: "Renamed Vault")
    #expect(try await provider.listAll(prefix: "").isEmpty)
  }

  @Test("should empty the index when the vault folder is moved and follow the folder a later put creates at its path")
  func followsMovedFolder() async throws {
    let harness = try OneDriveHarness()
    let provider = try harness.provider()
    _ = try await provider.put(try key("old"), data: Data([1]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["old"])
    let archive = harness.graph.seedFolder(name: "Archive")
    harness.graph.moveItem(named: OneDriveHarness.vault, in: FakeGraph.appFolderID, to: archive)
    #expect(try await provider.listAll(prefix: "").isEmpty)
    _ = try await provider.put(try key("new"), data: Data([2]), condition: .overwrite)
    #expect(try await provider.listAll(prefix: "").map(\.key.rawValue) == ["new"])
    #expect(await (harness.state as? InMemoryOneDriveStateStore)?.state?.appFolderID == FakeGraph.appFolderID)
  }

  @Test("should discard the upload session even when the put's task is cancelled")
  func cancelsSessionOnTaskCancellation() async throws {
    let graph = FakeGraph()
    let unit = OneDriveProviderOptions.fragmentUnit
    let transport = CancellingTransport(graph) { $0.url.host() == FakeGraph.uploadHost && $0.contentRange?.hasPrefix("bytes \(unit)-") == true }
    let harness = try OneDriveHarness(graph: graph)
    let provider = try OneDriveStorageProvider(
      configuration: harness.configuration, session: harness.session, transport: transport, stateStore: harness.state,
      options: OneDriveProviderOptions(simpleUploadLimit: 0, uploadFragmentBytes: unit))
    _ = try await provider.put(try key("seed"), data: Data(), condition: .overwrite)
    let big = try key("big")
    let error = await storageError { _ = try await provider.put(big, data: Data(repeating: 7, count: unit * 3), condition: .overwrite) }
    #expect(error == .unavailable("the request was cancelled"))
    #expect(graph.openSessions == 0)
    #expect(graph.fileNames == ["seed"])
  }

  @Test("should accept the largest incompressible segment the codec can seal")
  func fitsLargestSealedSegment() throws {
    let replica = try #require(ReplicaID("0192e4c1-7a2b-7c3d-8e4f-5a6b7c8d9e0f"))
    let vault = try #require(VaultID(String(repeating: "v", count: 64)))
    let keyID = try #require(KeyID(replica.description))
    let vaultKey = try #require(VaultKey(id: keyID, rawBytes: Data(repeating: 0x42, count: 32)))
    var lines = Self.randomLines(totalBytes: SegmentCodec.maximumPayloadBytes - 300)
    let header = try #require(SegmentHeader(replica: replica, first: 1, last: Int64(lines.count), previous: nil, dependencies: [:], schema: 1))
    let shortfall = SegmentCodec.maximumPayloadBytes - SegmentCodec.payload(of: try #require(SegmentFile(header: header, lines: lines))).count
    lines[lines.count - 1].append(Data(repeating: 0x7F, count: shortfall))
    let file = try #require(SegmentFile(header: header, lines: lines))
    #expect(SegmentCodec.payload(of: file).count == SegmentCodec.maximumPayloadBytes)
    let sealed = try SegmentCodec.seal(file, vault: vault, with: vaultKey)
    #expect(sealed.data.count > SegmentCodec.maximumPayloadBytes)
    #expect(sealed.data.count <= OneDriveProviderOptions().maxObjectBytes)
  }

  /// Uniform random bytes cut at their own newlines, so deflate cannot shrink them and the codec stores them as they are.
  private static func randomLines(totalBytes: Int) -> [Data] {
    var generator = SeededGenerator(seed: 0x5E6)
    var bytes = [UInt8](repeating: 0, count: totalBytes)
    for index in stride(from: 0, to: totalBytes, by: 8) {
      let word = generator.next()
      for offset in 0..<min(8, totalBytes - index) { bytes[index + offset] = UInt8(truncatingIfNeeded: word >> (offset * 8)) }
    }
    for index in bytes.indices where bytes[index] == 0x0A && (index == 0 || index == bytes.count - 1 || bytes[index - 1] == 0x0A) { bytes[index] = 0x0B }
    return bytes.split(separator: 0x0A).map { Data($0) }
  }
}
