import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Blob sync", TestTimeLimit.standard)
struct SyncBlobTests {
  @Test("should fetch on a second replica a blob put on the first, byte for byte")
  func shouldRoundTripAcrossReplicas() async throws {
    let peers = try await BlobPeers.make(2)
    let content = BlobFixture.content(10_000, seed: 1)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)

    try await peers.settle()

    #expect(try await peers[1].images()["r1"] == id)
    #expect(try await peers[1].blobs.localURL(of: id) == nil)
    #expect(try await peers[1].fetched(id) == content)
    #expect(try await peers[1].blobs.status(of: id) == .downloaded)
    #expect(try await peers[1].blobs.localURL(of: id) != nil)
    #expect(try await peers[0].blobs.status(of: id) == .stored)
    #expect(try await peers[0].fetched(id) == content)
  }

  @Test("should store a blob in parts that each fit the provider's object limit")
  func shouldSplitIntoParts() async throws {
    let provider = InMemoryStorageProvider(maxObjectBytes: 2048, serverClock: { SyncFixture.start })
    let peers = try await BlobPeers.make(2, provider: provider)
    let content = BlobFixture.content(9_000, seed: 2)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)

    try await peers.settle()

    let parts = try await provider.listAll(prefix: VaultPath.blobPrefix(id.description))
    #expect(parts.count > 4)
    #expect(parts.allSatisfy { $0.size <= 2048 })
    #expect(try await peers[1].fetched(id) == content)
  }

  @Test("should put waiting blobs before the segments that name them and retry both after a provider fault")
  func shouldRetryAfterFaults() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(1, provider: provider)
    let content = BlobFixture.content(5_000, seed: 3)
    let id = try await peers[0].blobs.put(content)
    try await peers[0].setImage("r1", id)
    provider.failPuts(under: VaultPath.blobsPrefix)
    let pending = try await peers[0].pendingLines()

    let error = await #expect(throws: SyncError.self) { try await peers[0].engine.upload() }
    guard case .storage(.unavailable)? = error else { throw SyncFixtureFailure("expected an unavailable storage, got \(String(describing: error))") }
    #expect(try await peers[0].blobs.status(of: id) == .waitingToUpload)
    #expect(try await peers[0].pendingLines() == pending)
    #expect(try await provider.listAll(prefix: VaultPath.replicasPrefix).allSatisfy { if case .segment = VaultPath.classify($0.key) { false } else { true } })

    provider.failPuts(under: nil)
    _ = try await peers[0].uploaded()

    #expect(try await peers[0].blobs.status(of: id) == .stored)
    #expect(try await peers[0].pendingLines().isEmpty)
    #expect(!(try await provider.blobKeys(id)).isEmpty)
  }

  @Test("should keep uploading changes while one blob's local file cannot be read, and put the blob once it can")
  func shouldSkipAnUnreadableBlob() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(1, provider: provider)
    let unreadable = try await peers[0].blobs.put(BlobFixture.content(500, seed: 11))
    let readable = try await peers[0].blobs.put(BlobFixture.content(500, seed: 12))
    try await peers[0].setImage("r1", unreadable)
    let file = try #require(try await peers[0].blobs.localURL(of: unreadable))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false)) }

    _ = try await peers[0].engine.upload()

    #expect(try await peers[0].pendingLines().isEmpty)
    #expect(try await peers[0].blobs.status(of: unreadable) == .waitingToUpload)
    #expect(try await peers[0].blobs.status(of: readable) == .stored)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    _ = try await peers[0].engine.upload()
    #expect(try await peers[0].blobs.status(of: unreadable) == .stored)
  }

  @Test("should resume the upload queue after a relaunch")
  func shouldResumeAfterRelaunch() async throws {
    let provider = BlobWatchingProvider()
    var peers = try await BlobPeers.make(1, provider: provider)
    let content = BlobFixture.content(3_000, seed: 4)
    let id = try await peers[0].blobs.put(content)
    provider.failPuts(under: VaultPath.blobsPrefix)
    await #expect(throws: SyncError.self) { try await peers[0].engine.upload() }
    let replica = peers[0].store.replica
    peers.peers = []
    provider.failPuts(under: nil)

    let relaunched = try await peers.join("peer0")

    #expect(relaunched.store.replica == replica)
    #expect(try await VaultBlobs.hasPendingUploads(in: relaunched.store))
    _ = try await relaunched.engine.upload()
    #expect(try await VaultBlobs.hasPendingUploads(in: relaunched.store) == false)
    #expect(try await relaunched.blobs.status(of: id) == .stored)
    let late = try await peers.join("late")
    #expect(try await late.fetched(id) == content)
  }

  @Test("should refuse a blob sealed with a key this device does not hold")
  func shouldRefuseWrongKey() async throws {
    let peers = try await BlobPeers.make(2, sharedKey: false)
    let id = try await peers[0].blobs.put(BlobFixture.content(100, seed: 5))
    _ = try await peers[0].engine.upload()

    let error = await #expect(throws: BlobError.self) { try await peers[1].engine.fetchBlob(id) }
    guard case .keyUnavailable(id, let key)? = error else { throw SyncFixtureFailure("expected keyUnavailable, got \(String(describing: error))") }
    #expect(peers[0].ring.key(key) != nil)
    #expect(try await peers[1].blobs.localURL(of: id) == nil)
  }

  @Test("should refuse a blob whose stored part was altered and keep no local copy")
  func shouldRefuseCorrupt() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(2, provider: provider)
    let id = try await peers[0].blobs.put(BlobFixture.content(6_000, seed: 6))
    _ = try await peers[0].engine.upload()
    let key = try #require(try await provider.blobKeys(id).last)
    var data = try await provider.get(key)
    data[data.index(data.endIndex, offsetBy: -20)] ^= 0x01
    _ = try await provider.inner.put(key, data: data, condition: .overwrite)

    let error = await #expect(throws: BlobError.self) { try await peers[1].engine.fetchBlob(id) }
    guard case .corrupt(id, _)? = error else { throw SyncFixtureFailure("expected corrupt, got \(String(describing: error))") }
    #expect(try await peers[1].blobs.localURL(of: id) == nil)
    #expect(try await peers[1].blobRow(id) == nil)
  }

  @Test("should refuse a part stored under another blob's name")
  func shouldRefuseMovedPart() async throws {
    let provider = BlobWatchingProvider()
    let peers = try await BlobPeers.make(2, provider: provider)
    let id = try await peers[0].blobs.put(BlobFixture.content(50, seed: 7))
    _ = try await peers[0].engine.upload()
    let other = BlobID.random()
    let source = try #require(try await provider.blobKeys(id).first)
    _ = try await provider.inner.put(VaultPath.blobPart(name: other.description, part: 1, parts: 1), data: try await provider.get(source), condition: .overwrite)

    let error = await #expect(throws: BlobError.self) { try await peers[1].engine.fetchBlob(other) }
    guard case .corrupt(other, _)? = error else { throw SyncFixtureFailure("expected corrupt, got \(String(describing: error))") }
  }

  @Test("should report a blob nobody stored as missing")
  func shouldReportMissing() async throws {
    let peers = try await BlobPeers.make(1)
    let id = BlobID.random()

    let error = await #expect(throws: BlobError.self) { try await peers[0].engine.fetchBlob(id) }
    guard case .missing(id)? = error else { throw SyncFixtureFailure("expected missing, got \(String(describing: error))") }
  }

  @Test("should put nothing for a health-class blob on an iCloud provider and refuse to fetch one")
  func shouldRefuseHealthOnICloud() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let peers = try await BlobPeers.make(1, provider: provider, registry: BlobFixture.healthRegistry)
    let id = try await peers[0].blobs.put(BlobFixture.content(100, seed: 8))

    let error = await #expect(throws: SyncError.self) { try await peers[0].engine.upload() }
    guard case .blob(.classRefused(.health))? = error else { throw SyncFixtureFailure("expected classRefused, got \(String(describing: error))") }
    let compaction = await #expect(throws: SyncError.self) { try await peers[0].engine.compact(force: true) }
    guard case .blob(.classRefused(.health))? = compaction else { throw SyncFixtureFailure("expected classRefused, got \(String(describing: compaction))") }
    let fetch = await #expect(throws: BlobError.self) { try await peers[0].engine.fetchBlob(BlobID.random()) }
    guard case .classRefused(.health)? = fetch else { throw SyncFixtureFailure("expected classRefused, got \(String(describing: fetch))") }

    #expect(provider.callCounts.put == 0)
    #expect(try await provider.listAll(prefix: VaultPath.blobsPrefix).isEmpty)
    #expect(try await peers[0].blobs.status(of: id) == .waitingToUpload)
  }

  @Test("should upload a general-class store's blob to an iCloud provider")
  func shouldUploadGeneralOnICloud() async throws {
    let provider = InMemoryStorageProvider(classPolicy: .iCloud)
    let peers = try await BlobPeers.make(1, provider: provider)
    let id = try await peers[0].blobs.put(BlobFixture.content(100, seed: 9))

    _ = try await peers[0].engine.upload()

    #expect(try await peers[0].blobs.status(of: id) == .stored)
  }

  @Test("should refuse a blob over the size limit and keep nothing of it")
  func shouldRefuseTooLarge() async throws {
    let peers = try await BlobPeers.make(1)
    let blobs = try VaultBlobs(store: peers[0].store, maximumBytes: 10)

    let error = await #expect(throws: BlobError.self) { try await blobs.put(Data(count: 11)) }
    guard case .tooLarge(size: 11, limit: 10)? = error else { throw SyncFixtureFailure("expected tooLarge, got \(String(describing: error))") }
    let source = peers.directory.url.appending(path: "large.bin")
    try Data(count: 12).write(to: source)
    let copied = await #expect(throws: BlobError.self) { try await blobs.put(contentsOf: source) }
    guard case .tooLarge(size: 12, limit: 10)? = copied else { throw SyncFixtureFailure("expected tooLarge, got \(String(describing: copied))") }
    #expect(try await VaultBlobs.hasPendingUploads(in: peers[0].store) == false)
    let folder = try #require(peers[0].store.blobDirectory)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty ?? true)
  }

  @Test("should put a file's contents without changing them")
  func shouldPutFile() async throws {
    let peers = try await BlobPeers.make(2)
    let content = BlobFixture.content(20_000, seed: 10)
    let source = peers.directory.url.appending(path: "receipt.jpg")
    try FileManager.default.createDirectory(at: peers.directory.url, withIntermediateDirectories: true)
    try content.write(to: source)

    let id = try await peers[0].blobs.put(contentsOf: source)
    _ = try await peers[0].engine.upload()

    #expect(try Data(contentsOf: try #require(try await peers[0].blobs.localURL(of: id))) == content)
    #expect(try await peers[1].fetched(id) == content)
  }

  @Test("should keep no blobs for an in-memory store")
  func shouldRefuseInMemory() throws {
    let store = try SyncFixture.open(registry: BlobFixture.registry)

    #expect(store.blobDirectory == nil)
    #expect(throws: BlobError.self) { try VaultBlobs(store: store) }
  }

  @Test("should keep a restricted store's blobs inside its backup-excluded directory across reopening")
  func shouldKeepBlobsInsideAnExcludedDirectory() async throws {
    let directory = BlobDirectory()
    let url = directory.database("health")
    let open = { () throws -> VaultStore in
      try VaultStore.open(.file(url), registry: BlobFixture.healthRegistry, migrations: SyncEngine.migrations, wallClock: { SyncFixture.start }, backup: .alwaysExcluded)
    }
    let id = try await VaultBlobs(store: try open()).put(Data("scan".utf8))

    let reopened = try open()

    let folder = try #require(reopened.blobDirectory)
    #expect(folder.deletingLastPathComponent() == url.deletingLastPathComponent())
    #expect(try await VaultBlobs(store: reopened).localURL(of: id) == folder.appending(path: id.description))
    var parent = url.deletingLastPathComponent()
    parent.removeAllCachedResourceValues()
    #expect(try parent.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }
}
