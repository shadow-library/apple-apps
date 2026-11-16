import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("SegmentCodec")
struct SegmentCodecTests {
  static let replica = "01936f3e-1111-7111-8111-111111111111"
  static let dependency = "01936f3e-2222-7222-8222-222222222222"
  static let previousTag = "0123456789abcdef0123456789abcdef"
  static let dependencyTag = "fedcba9876543210fedcba9876543210"
  static let goldenPayload = """
    {"count":2,"deps":{"\(dependency)":{"last":17,"tag":"\(dependencyTag)"}},"first":5,"format":1,"kind":"segment","last":6,\
    "prev":{"last":4,"tag":"\(previousTag)"},"replica":"\(replica)","schema":3}
    {"id":"a","n":1}
    {"id":"b","n":2}

    """
  static let goldenKey = "replicas/\(replica)/seg/000000000005-000000000006-f10474a86e4b8e3cfaf91e740c7a7ebf"

  static func goldenFile() throws -> SegmentFile {
    let header = try #require(
      SegmentHeader(
        replica: try CodecFixtures.replica(replica),
        first: 5,
        last: 6,
        previous: StreamPoint(last: 4, tag: try CodecFixtures.tag(previousTag)),
        dependencies: [try CodecFixtures.replica(dependency): StreamPoint(last: 17, tag: try CodecFixtures.tag(dependencyTag))],
        schema: 3
      )
    )
    return try #require(SegmentFile(header: header, lines: [Data("{\"id\":\"a\",\"n\":1}".utf8), Data("{\"id\":\"b\",\"n\":2}".utf8)]))
  }

  @Test("should pin the payload bytes and the object key of the golden segment")
  func shouldMatchGoldenVector() throws {
    let file = try Self.goldenFile()
    let key = try CodecFixtures.key()
    #expect(String(decoding: SegmentCodec.payload(of: file), as: UTF8.self) == Self.goldenPayload)
    let sealed = try SegmentCodec.seal(file, vault: try CodecFixtures.vault(), with: key)
    #expect(sealed.key.rawValue == Self.goldenKey)
    #expect(sealed.tag == ContentTag.make(for: Data(Self.goldenPayload.utf8), key: key))
    #expect(try SegmentCodec.open(sealed.data, at: sealed.key, vault: try CodecFixtures.vault(), keys: CodecFixtures.ring(key)) == file)
  }

  @Test("should round trip random headers and lines")
  func shouldRoundTripRandomSegments() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    try forAll(iterations: 150) { generator in
      let file = try CodecFixtures.segment(&generator)
      let sealed = try SegmentCodec.seal(file, vault: vault, with: key)
      #expect(VaultPath.classify(sealed.key) == .segment(file.header.replica, first: file.header.first, last: file.header.last, tag: sealed.tag))
      #expect(sealed.tag == ContentTag.make(for: SegmentCodec.payload(of: file), key: key))
      #expect(try SegmentCodec.open(sealed.data, at: sealed.key, vault: vault, keys: CodecFixtures.ring(key)) == file)
    }
  }

  @Test("should repeat the same name for the same content and key while the sealed bytes differ")
  func shouldBeDeterministicInName() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let first = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: key)
    let second = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: key)
    let otherKey = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: try CodecFixtures.key(byte: 0x07))
    #expect(first.key == second.key)
    #expect(first.tag == second.tag)
    #expect(first.data != second.data)
    let openedFirst = try SegmentCodec.open(first.data, at: first.key, vault: vault, keys: CodecFixtures.ring(key))
    #expect(try SegmentCodec.open(second.data, at: second.key, vault: vault, keys: CodecFixtures.ring(key)) == openedFirst)
    #expect(otherKey.key != first.key)
  }

  @Test("should open a segment through a ring that holds several keys, using the one that sealed it")
  func shouldOpenWithRing() throws {
    let sealing = try CodecFixtures.key(id: "01936f3e-0000-7000-8000-00000000000b", byte: 0x0B)
    let vault = try CodecFixtures.vault()
    let sealed = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: sealing)
    #expect(try SegmentCodec.open(sealed.data, at: sealed.key, vault: vault, keys: CodecFixtures.ring(try CodecFixtures.key(), sealing)) == Self.goldenFile())
  }

  @Test("should store compressible payloads with DEFLATE and incompressible ones as they are")
  func shouldChooseCodec() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let replica = try CodecFixtures.replica(Self.replica)
    let repetitive = Array(repeating: Data("{\"entity\":\"bible_page\",\"kind\":\"set\",\"fields\":{\"title\":\"The Ember Court\"}}".utf8), count: 40)
    let compressibleHeader = try #require(SegmentHeader(replica: replica, first: 1, last: 40, previous: nil, dependencies: [:], schema: 1))
    let compressible = try #require(SegmentFile(header: compressibleHeader, lines: repetitive))
    let sealedCompressible = try SegmentCodec.seal(compressible, vault: vault, with: key)
    #expect(try CodecFixtures.codecByte(of: sealedCompressible.data, at: sealedCompressible.key, vault: vault, keys: CodecFixtures.ring(key)) == CodecFrame.deflateCodec)
    #expect(try SegmentCodec.open(sealedCompressible.data, at: sealedCompressible.key, vault: vault, keys: CodecFixtures.ring(key)) == compressible)

    var generator = SeededGenerator(seed: 0xD1CE)
    let random = CodecFixtures.lines(&generator, count: 3, maxLength: 4000)
    let incompressibleHeader = try #require(SegmentHeader(replica: replica, first: 1, last: 3, previous: nil, dependencies: [:], schema: 1))
    let incompressible = try #require(SegmentFile(header: incompressibleHeader, lines: random))
    let sealedIncompressible = try SegmentCodec.seal(incompressible, vault: vault, with: key)
    #expect(try CodecFixtures.codecByte(of: sealedIncompressible.data, at: sealedIncompressible.key, vault: vault, keys: CodecFixtures.ring(key)) == CodecFrame.storedCodec)
    #expect(try SegmentCodec.open(sealedIncompressible.data, at: sealedIncompressible.key, vault: vault, keys: CodecFixtures.ring(key)) == incompressible)
  }

  @Test("should fail authentication when a segment is moved to another replica, another last or another tag")
  func shouldRejectMovedSegments() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let file = try Self.goldenFile()
    let sealed = try SegmentCodec.seal(file, vault: vault, with: key)
    let otherReplica = try CodecFixtures.replica("01936f3e-3333-7333-8333-333333333333")
    let moves = [
      VaultPath.segment(otherReplica, first: 5, last: 6, tag: sealed.tag),
      VaultPath.segment(file.header.replica, first: 5, last: 7, tag: sealed.tag),
      VaultPath.segment(file.header.replica, first: 5, last: 6, tag: try CodecFixtures.tag(Self.previousTag)),
    ]
    for moved in moves {
      #expect(throws: VaultCodecError.file(.authenticationFailed)) { try SegmentCodec.open(sealed.data, at: moved, vault: vault, keys: CodecFixtures.ring(key)) }
    }
  }

  @Test("should reject a key that does not name a segment before decrypting")
  func shouldRejectNonSegmentKey() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let sealed = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: key)
    let manifest = VaultPath.manifest(try CodecFixtures.replica(Self.replica))
    #expect(throws: VaultCodecError.pathMismatch) { try SegmentCodec.open(sealed.data, at: manifest, vault: vault, keys: CodecFixtures.ring(key)) }
  }

  @Test("should reject a segment from another vault or sealed with a key the ring lacks")
  func shouldRejectWrongVaultAndUnknownKey() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let other = try CodecFixtures.vault("vault-two")
    let sealed = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: key)
    #expect(throws: VaultCodecError.file(.vaultMismatch(expected: other, found: vault))) {
      try SegmentCodec.open(sealed.data, at: sealed.key, vault: other, keys: CodecFixtures.ring(key))
    }
    #expect(throws: VaultCodecError.file(.keyUnavailable(key.id))) { try SegmentCodec.open(sealed.data, at: sealed.key, vault: vault, keys: { _ in nil }) }
  }

  @Test("should open a sealed segment passed as a slice with a non-zero start index")
  func shouldOpenSlicedInput() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let sealed = try SegmentCodec.seal(try Self.goldenFile(), vault: vault, with: key)
    let slice = (Data([9, 9]) + sealed.data + Data([9])).dropFirst(2).dropLast()
    let opened = try SegmentCodec.open(slice, at: sealed.key, vault: vault, keys: CodecFixtures.ring(key))
    #expect(opened == (try Self.goldenFile()))
    #expect(opened.lines.allSatisfy { $0.startIndex == 0 })
  }

  @Test("should enforce the header rules in the initialiser")
  func shouldEnforceHeaderRules() throws {
    let replica = try CodecFixtures.replica(Self.replica)
    let other = try CodecFixtures.replica(Self.dependency)
    let tag = try CodecFixtures.tag(Self.previousTag)
    let point = StreamPoint(last: 4, tag: tag)
    #expect(SegmentHeader(replica: replica, first: 1, last: 1, previous: nil, dependencies: [:], schema: 0) != nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: point, dependencies: [other: point], schema: 0) != nil)
    let maximum = VaultPath.maximumSequence
    #expect(SegmentHeader(replica: replica, first: maximum, last: maximum, previous: StreamPoint(last: maximum - 1, tag: tag), dependencies: [:], schema: 0) != nil)
    #expect(SegmentHeader(replica: replica, first: 0, last: 1, previous: nil, dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 2, last: 1, previous: StreamPoint(last: 1, tag: tag), dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 1, last: 1_000_000_000_000, previous: nil, dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 1, last: 1, previous: StreamPoint(last: 0, tag: tag), dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: nil, dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: StreamPoint(last: 3, tag: tag), dependencies: [:], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: point, dependencies: [replica: point], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: point, dependencies: [other: StreamPoint(last: 0, tag: tag)], schema: 0) == nil)
    #expect(SegmentHeader(replica: replica, first: 5, last: 5, previous: point, dependencies: [:], schema: -1) == nil)
  }

  @Test("should enforce the line rules in the file initialiser")
  func shouldEnforceLineRules() throws {
    let header = try #require(SegmentHeader(replica: try CodecFixtures.replica(Self.replica), first: 1, last: 2, previous: nil, dependencies: [:], schema: 0))
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data("b".utf8)]) != nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8)]) == nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data("b".utf8), Data("c".utf8)]) == nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data()]) == nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data("b\nc".utf8)]) == nil)
    #expect(SegmentFile(header: header, lines: [Data("a\r".utf8), Data([0x00, 0xFF])]) != nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data("b".utf8)], lineLimit: 2) != nil)
    #expect(SegmentFile(header: header, lines: [Data("a".utf8), Data("b".utf8)], lineLimit: 1) == nil)
    #expect(SegmentCodec.maximumLineCount == 1_048_576)
  }
}
