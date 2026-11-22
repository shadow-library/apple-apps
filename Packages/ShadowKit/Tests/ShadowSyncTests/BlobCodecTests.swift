import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("BlobCodec", TestTimeLimit.quick)
struct BlobCodecTests {
  private final class Source {
    let url = FileManager.default.temporaryDirectory.appending(path: "shadow-blob-codec-\(UUID().uuidString)")
    let handle: FileHandle

    init(_ data: Data) throws {
      try data.write(to: url)
      handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
      try? handle.close()
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func header(_ id: BlobID, _ content: Data, part: Int = 1, parts: Int = 1, offset: Int = 0, length: Int? = nil) -> BlobPartHeader {
    BlobPartHeader(
      blob: id, syncClass: .general, digest: BlobCodec.digest(of: content), size: content.count, part: part, parts: parts, offset: offset,
      length: length ?? content.count)
  }

  private func open(_ sealed: Data, at key: ObjectKey, keys: [VaultKey]) throws(BlobError) -> (BlobPartHeader, Data) {
    var bytes = Data()
    let collect = { (chunk: Data) throws(BlobError) in bytes.append(chunk) }
    let header = try BlobCodec.open(sealed, at: key, vault: SyncFixture.vault, keys: { id in keys.first { $0.id == id } }, sink: collect)
    return (header, bytes)
  }

  @Test("should seal and open a part spanning several cipher chunks")
  func shouldRoundTrip() throws {
    let key = try VaultFileFixtures.key(byte: 0x01)
    let content = BlobFixture.content(3 * VaultFile.defaultChunkSize + 17, seed: 31)
    let id = BlobID.random()
    let source = try Source(content)
    let header = header(id, content)

    let sealed = try BlobCodec.seal(header, from: source.handle, vault: SyncFixture.vault, key: key)
    let (opened, bytes) = try open(sealed, at: VaultPath.blobPart(name: id.description, part: 1, parts: 1), keys: [key])

    #expect(opened == header)
    #expect(bytes == content)
    #expect(sealed.count <= BlobCodec.sealedLength(payload: content.count, vault: SyncFixture.vault))
  }

  @Test("should seal the slice of a later part and an empty blob")
  func shouldSealSlices() throws {
    let key = try VaultFileFixtures.key(byte: 0x02)
    let content = BlobFixture.content(1_000, seed: 32)
    let id = BlobID.random()
    let source = try Source(content)
    let second = header(id, content, part: 2, parts: 2, offset: 600, length: 400)
    let empty = try Source(Data())

    let sealed = try BlobCodec.seal(second, from: source.handle, vault: SyncFixture.vault, key: key)
    let sealedEmpty = try BlobCodec.seal(header(id, Data()), from: empty.handle, vault: SyncFixture.vault, key: key)

    #expect(try open(sealed, at: VaultPath.blobPart(name: id.description, part: 2, parts: 2), keys: [key]).1 == content[600...])
    #expect(try open(sealedEmpty, at: VaultPath.blobPart(name: id.description, part: 1, parts: 1), keys: [key]).1.isEmpty)
  }

  @Test("should name the missing key when the part is sealed with a key the ring lacks")
  func shouldRefuseWrongKey() throws {
    let key = try VaultFileFixtures.key(id: SyncFixture.keyID(1), byte: 0x03)
    let other = try VaultFileFixtures.key(id: SyncFixture.keyID(2), byte: 0x03)
    let content = Data("receipt".utf8)
    let id = BlobID.random()
    let source = try Source(content)
    let sealed = try BlobCodec.seal(header(id, content), from: source.handle, vault: SyncFixture.vault, key: key)

    #expect(throws: BlobError.self) { try open(sealed, at: VaultPath.blobPart(name: id.description, part: 1, parts: 1), keys: [other]) }
    do {
      _ = try open(sealed, at: VaultPath.blobPart(name: id.description, part: 1, parts: 1), keys: [other])
    } catch {
      guard case .keyUnavailable(id, SyncFixture.keyID(1)) = error else { throw SyncFixtureFailure("expected keyUnavailable, got \(error)") }
    }
  }

  @Test("should refuse a part whose bytes, name or key material differ")
  func shouldRefuseTampering() throws {
    let key = try VaultFileFixtures.key(byte: 0x04)
    let impostor = try VaultFileFixtures.key(id: key.id, byte: 0x05)
    let content = BlobFixture.content(500, seed: 33)
    let id = BlobID.random()
    let path = VaultPath.blobPart(name: id.description, part: 1, parts: 1)
    let source = try Source(content)
    var sealed = try BlobCodec.seal(header(id, content), from: source.handle, vault: SyncFixture.vault, key: key)
    let original = sealed
    sealed[sealed.index(sealed.endIndex, offsetBy: -30)] ^= 0x80

    for (data, key, path) in [
      (sealed, key, path), (original, impostor, path), (original, key, VaultPath.blobPart(name: BlobID.random().description, part: 1, parts: 1)),
      (original, key, VaultPath.blobPart(name: id.description, part: 1, parts: 2)), (original.prefix(original.count - 5), key, path),
    ] {
      do {
        _ = try open(Data(data), at: path, keys: [key])
        throw SyncFixtureFailure("a tampered part opened")
      } catch let error as BlobError {
        guard case .corrupt = error else { throw SyncFixtureFailure("expected corrupt, got \(error)") }
      }
    }
  }

  @Test("should lay out parts that fit the limit and refuse a limit no part fits")
  func shouldLayOutParts() throws {
    let unlimited = try #require(BlobCodec.layout(size: 10_000, partBytes: 4096, limit: .max, vault: SyncFixture.vault))
    let tight = try #require(BlobCodec.layout(size: 10_000, partBytes: 4096, limit: 1500, vault: SyncFixture.vault))

    #expect(unlimited == [0..<4096, 4096..<8192, 8192..<10_000])
    #expect(tight.count > 10 && tight.allSatisfy { BlobCodec.sealedLength(payload: $0.count, vault: SyncFixture.vault) <= 1500 })
    #expect(tight.first?.lowerBound == 0 && tight.last?.upperBound == 10_000)
    #expect(zip(tight, tight.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
    #expect(BlobCodec.layout(size: 0, partBytes: 4096, limit: .max, vault: SyncFixture.vault) == [0..<0])
    #expect(BlobCodec.layout(size: 10, partBytes: 4096, limit: 200, vault: SyncFixture.vault) == nil)
  }
}

@Suite("BlobID", TestTimeLimit.quick)
struct BlobIDTests {
  @Test("should accept only 64 lower-case hex characters")
  func shouldValidate() {
    let id = BlobID.random()

    #expect(BlobID(id.description) == id)
    #expect(BlobID.random() != id)
    #expect(BlobID(String(repeating: "a", count: 63)) == nil)
    #expect(BlobID(String(repeating: "A", count: 64)) == nil)
    #expect(BlobID(String(repeating: "g", count: 64)) == nil)
  }

  @Test("should find candidate ids in JSON strings and longer hex runs and nothing else")
  func shouldFindCandidates() throws {
    let first = BlobID.random()
    let second = BlobID.random()
    let absent = BlobID.random()
    let other = BlobID.random()
    let bytes = Data(
      "{\"image\":\"\(first.description)\",\"note\":\"![](blob:0\(second.description)\",\"key\":\"\(other.description)\",\"tag\":\"\(String(repeating: "f", count: 63))\"}".utf8)
    let matcher = BlobIDMatcher([first, second, absent])

    var found = Set<BlobID>()
    let unfinished = matcher.scan(bytes, into: &found)

    #expect(found == [first, second])
    #expect(unfinished)
    #expect(!matcher.scan(Data(absent.description.utf8), into: &found))
    #expect(found == [first, second, absent])
  }
}
