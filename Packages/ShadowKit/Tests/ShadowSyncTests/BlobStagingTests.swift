import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Blob staging", TestTimeLimit.standard)
struct BlobStagingTests {
  @Test("should keep a restored blob under its exported id, upload it with the import that names it and fetch it on another replica")
  func shouldUploadAStagedBlob() async throws {
    let peers = try await BlobPeers.make(2)
    let content = BlobFixture.content(10_000, seed: 7)
    let source = try Self.file(content, in: peers.directory)
    let id = try #require(BlobID(String(repeating: "c4", count: 32)))

    let staged = try await peers[0].blobs.stage(contentsOf: source, as: id)
    #expect(try await peers[0].blobs.status(of: id) == nil, "nothing knows a staged blob before its import")
    _ = try await VaultStore.importEntities([
      StoreImport(store: peers[0].store, entities: [.record(BlobFixture.ref("r1"), fields: ["image": .string(id.description)])], kinds: [BlobFixture.receipt]) {
        database in try staged.record(in: database)
      }
    ])
    #expect(try await peers[0].blobs.status(of: id) == .waitingToUpload)

    try await peers.settle()

    #expect(try await peers[1].images()["r1"] == id)
    #expect(try await peers[1].fetched(id) == content)
  }

  @Test("should refuse an id the store holds and remove a staged file whose import failed")
  func shouldRefuseAHeldIdAndDiscard() async throws {
    let peers = try await BlobPeers.make(1)
    let source = try Self.file(BlobFixture.content(100, seed: 8), in: peers.directory)
    let held = try await peers[0].blobs.put(BlobFixture.content(50, seed: 9))

    let error = await #expect(throws: BlobError.self) { _ = try await peers[0].blobs.stage(contentsOf: source, as: held) }
    guard case .alreadyHeld(held)? = error else { throw SyncFixtureFailure("expected alreadyHeld, got \(String(describing: error))") }

    let id = try #require(BlobID(String(repeating: "d5", count: 32)))
    let staged = try await peers[0].blobs.stage(contentsOf: source, as: id)
    let file = try #require(peers[0].store.blobDirectory).appending(path: id.description)
    #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    try peers[0].blobs.discard(staged)
    #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    #expect(try await peers[0].blobs.status(of: id) == nil)
  }

  @Test("should replace a file a restore left without its row, as after a crash before the import committed")
  func shouldReplaceALeftoverFile() async throws {
    let peers = try await BlobPeers.make(1)
    let content = BlobFixture.content(200, seed: 10)
    let source = try Self.file(content, in: peers.directory)
    let id = try #require(BlobID(String(repeating: "e6", count: 32)))
    let directory = try #require(peers[0].store.blobDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("left by a stopped restore".utf8).write(to: directory.appending(path: id.description))

    let staged = try await peers[0].blobs.stage(contentsOf: source, as: id)
    _ = try await VaultStore.importEntities([
      StoreImport(store: peers[0].store, entities: [.record(BlobFixture.ref("r1"), fields: ["image": .string(id.description)])], kinds: [BlobFixture.receipt]) {
        database in try staged.record(in: database)
      }
    ])

    #expect(try Data(contentsOf: directory.appending(path: id.description)) == content)
    #expect(try await peers[0].blobs.status(of: id) == .waitingToUpload)
  }

  private static func file(_ content: Data, in directory: BlobDirectory) throws -> URL {
    let url = directory.url.appending(path: "source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
    try content.write(to: url)
    return url
  }
}
