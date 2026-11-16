import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("BaseCodec")
struct BaseCodecTests {
  static let replica = SegmentCodecTests.replica
  static let throughTag = SegmentCodecTests.previousTag
  static let goldenPayload = """
    {"count":2,"format":1,"kind":"base","lines":2,"part":1,"parts":1,"replica":"\(replica)","schema":2,\
    "through":{"last":9,"tag":"\(throughTag)"},"upto":12}
    {"id":"a"}
    {"id":"b"}

    """
  static let goldenLogicalContent = """
    {"format":1,"kind":"base","lines":2,"replica":"\(replica)","schema":2,"through":{"last":9,"tag":"\(throughTag)"},"upto":12}
    {"id":"a"}
    {"id":"b"}

    """
  static let goldenKey = "replicas/\(replica)/base/000000000012-dba016037b7fae741a16e8ea41e32e71/0001-of-0001"

  static func header(upTo: Int64 = 12, through: Int64? = 9) throws -> BaseHeader {
    let point = try through.map { StreamPoint(last: $0, tag: try CodecFixtures.tag(throughTag)) }
    return try #require(BaseHeader(replica: try CodecFixtures.replica(replica), upTo: upTo, through: point, schema: 2))
  }

  static func file(_ lines: [Data], header: BaseHeader? = nil) throws -> BaseFile {
    try #require(BaseFile(header: try header ?? Self.header(), lines: lines))
  }

  static func open(_ sealed: [SealedFile], keys: (KeyID) -> VaultKey?) throws -> [BasePart] {
    let vault = try CodecFixtures.vault()
    return try sealed.map { try BaseCodec.openPart($0.data, at: $0.key, vault: vault, keys: keys) }
  }

  static func singlePartSize(_ lines: [Data]) throws -> Int {
    let payloads = try BaseCodec.partPayloads(of: try file(lines), partPayloadBytes: BaseCodec.maximumPartPayloadBytes)
    try #require(payloads.count == 1)
    return payloads[0].count
  }

  @Test("should pin the part payload, the logical tag and the object key of the golden base")
  func shouldMatchGoldenVector() throws {
    let key = try CodecFixtures.key()
    let file = try Self.file([Data("{\"id\":\"a\"}".utf8), Data("{\"id\":\"b\"}".utf8)])
    let payloads = try BaseCodec.partPayloads(of: file, partPayloadBytes: BaseCodec.defaultPartPayloadBytes)
    #expect(payloads.map { String(decoding: $0, as: UTF8.self) } == [Self.goldenPayload])
    let sealed = try BaseCodec.seal(file, vault: try CodecFixtures.vault(), with: key)
    #expect(sealed.map(\.key.rawValue) == [Self.goldenKey])
    #expect(sealed.first?.tag == ContentTag.make(for: Data(Self.goldenLogicalContent.utf8), key: key))
    #expect(try BaseCodec.assemble(try Self.open(sealed, keys: CodecFixtures.ring(key)), keys: CodecFixtures.ring(key)) == file)
  }

  @Test("should round trip random bases in one part and in many parts")
  func shouldRoundTripRandomBases() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    try forAll(iterations: 60) { generator in
      let upTo = Int64(generator.int(in: 0...1_000_000))
      let through = upTo > 0 && generator.chance(0.7) ? StreamPoint(last: Int64(generator.int(in: 1...Int(upTo))), tag: try CodecFixtures.tag(&generator)) : nil
      let header = try #require(BaseHeader(replica: try CodecFixtures.replica(&generator), upTo: upTo, through: through, schema: generator.int(in: 0...9)))
      let file = try Self.file(CodecFixtures.lines(&generator, count: generator.int(in: 0...60), maxLength: 80), header: header)
      let limit = generator.chance(0.3) ? BaseCodec.defaultPartPayloadBytes : generator.int(in: 400...1200)
      let payloads = try BaseCodec.partPayloads(of: file, partPayloadBytes: limit)
      #expect(payloads.allSatisfy { $0.count <= limit })
      let sealed = try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: limit)
      #expect(sealed.count == payloads.count)
      for (index, part) in sealed.enumerated() {
        #expect(VaultPath.classify(part.key) == .basePart(header.replica, upTo: upTo, tag: part.tag, part: index + 1, parts: sealed.count))
      }
      let parts = try Self.open(sealed, keys: CodecFixtures.ring(key))
      #expect(try BaseCodec.assemble(generator.shuffled(parts), keys: CodecFixtures.ring(key)) == file)
    }
  }

  @Test("should split many lines into several full parts")
  func shouldSplitIntoManyParts() throws {
    let key = try CodecFixtures.key()
    var generator = SeededGenerator(seed: 0xBA5E)
    let file = try Self.file(CodecFixtures.lines(&generator, count: 200, maxLength: 60))
    let sealed = try BaseCodec.seal(file, vault: try CodecFixtures.vault(), with: key, partPayloadBytes: 600)
    #expect(sealed.count > 10)
    #expect(Set(sealed.map(\.tag)).count == 1)
    let parts = try Self.open(sealed, keys: CodecFixtures.ring(key))
    #expect(parts.map(\.part) == Array(1...sealed.count))
    #expect(parts.allSatisfy { $0.parts == sealed.count && $0.totalLines == 200 && !$0.lines.isEmpty })
    #expect(try BaseCodec.assemble(parts.reversed(), keys: CodecFixtures.ring(key)) == file)
  }

  @Test("should fit a line that exactly fills a part and reject one a byte longer")
  func shouldHandleExactBoundary() throws {
    let line = Data(repeating: UInt8(ascii: "x"), count: 100)
    let exact = try Self.singlePartSize([line])
    let payloads = try BaseCodec.partPayloads(of: try Self.file([line]), partPayloadBytes: exact)
    #expect(payloads.map(\.count) == [exact])
    #expect(throws: VaultCodecError.lineTooLarge(index: 0)) { try BaseCodec.partPayloads(of: try Self.file([line]), partPayloadBytes: exact - 1) }

    let second = Data(repeating: UInt8(ascii: "y"), count: 100)
    let both = try Self.singlePartSize([line, second])
    #expect(try BaseCodec.partPayloads(of: try Self.file([line, second]), partPayloadBytes: both).count == 1)
    let split = try BaseCodec.partPayloads(of: try Self.file([line, second]), partPayloadBytes: both - 1)
    #expect(split.count == 2)
    #expect(split.allSatisfy { $0.count <= both - 1 })
    #expect(throws: VaultCodecError.lineTooLarge(index: 1)) {
      try BaseCodec.partPayloads(of: try Self.file([line, second + Data("z".utf8)]), partPayloadBytes: exact)
    }
  }

  @Test("should count the digits of the number of parts when packing")
  func shouldAccountForPartsDigits() throws {
    let lines = (0..<12).map { _ in Data(repeating: UInt8(ascii: "q"), count: 10) }
    let single = try Self.singlePartSize([lines[0]])
    let payloads = try BaseCodec.partPayloads(of: try Self.file(lines), partPayloadBytes: single + 3)
    #expect(payloads.count == 12)
    #expect(payloads.map(\.count) == Array(repeating: single + 2, count: 9) + Array(repeating: single + 3, count: 3))
    #expect(String(decoding: payloads[11], as: UTF8.self).contains("\"part\":12,\"parts\":12"))
    #expect(throws: VaultCodecError.lineTooLarge(index: 9)) { try BaseCodec.partPayloads(of: try Self.file(lines), partPayloadBytes: single + 2) }
  }

  @Test("should accept 9999 parts and reject a base that needs more")
  func shouldLimitPartCount() throws {
    let line = Data(repeating: UInt8(ascii: "w"), count: 10)
    let single = try Self.singlePartSize([line])
    #expect(try BaseCodec.partPayloads(of: try Self.file(Array(repeating: line, count: 9999)), partPayloadBytes: single + 9).count == 9999)
    #expect(throws: VaultCodecError.tooManyParts) { try BaseCodec.partPayloads(of: try Self.file(Array(repeating: line, count: 10000)), partPayloadBytes: single + 10) }
  }

  @Test("should start a new part when a part reaches the line limit")
  func shouldRespectLineLimit() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let lines = (0..<10).map { Data("line \($0)".utf8) }
    let file = try Self.file(lines)
    let payloads = try BaseCodec.partPayloads(of: file, partPayloadBytes: BaseCodec.defaultPartPayloadBytes, lineLimit: 3)
    #expect(payloads.count == 4)
    let parts = try payloads.enumerated().map { index, payload in
      let objectKey = VaultPath.basePart(file.header.replica, upTo: file.header.upTo, tag: try CodecFixtures.tag(Self.throughTag), part: index + 1, parts: payloads.count)
      let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
      return try BaseCodec.openPart(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: BaseCodec.maximumPartPayloadBytes, lineLimit: 3)
    }
    #expect(parts.map(\.lines.count) == [3, 3, 3, 1])
    #expect(parts.flatMap(\.lines) == lines)
    #expect(try BaseCodec.partPayloads(of: file, partPayloadBytes: BaseCodec.defaultPartPayloadBytes, lineLimit: 10).count == 1)
    #expect(BaseCodec.maximumLineCount == SegmentCodec.maximumLineCount)
  }

  @Test("should throw a typed error for a part payload limit outside the allowed range", arguments: [Int.min, -1, 0, BaseCodec.maximumPartPayloadBytes + 1, Int.max])
  func shouldRejectInvalidPartPayloadBytes(bytes: Int) throws {
    let file = try Self.file([Data("a".utf8)])
    #expect(throws: VaultCodecError.invalidPartPayloadBytes(bytes)) {
      try BaseCodec.seal(file, vault: try CodecFixtures.vault(), with: try CodecFixtures.key(), partPayloadBytes: bytes)
    }
  }

  @Test("should seal an empty base as one part with no lines")
  func shouldSealEmptyBase() throws {
    let key = try CodecFixtures.key()
    let file = try Self.file([], header: try Self.header(upTo: 0, through: nil))
    let sealed = try BaseCodec.seal(file, vault: try CodecFixtures.vault(), with: key)
    #expect(sealed.count == 1)
    #expect(sealed[0].key.rawValue.hasSuffix("/0001-of-0001"))
    let parts = try Self.open(sealed, keys: CodecFixtures.ring(key))
    #expect(parts.first?.lines == [])
    #expect(parts.first?.totalLines == 0)
    #expect(try BaseCodec.assemble(parts, keys: CodecFixtures.ring(key)) == file)
    #expect(throws: VaultCodecError.payloadTooLarge) { try BaseCodec.partPayloads(of: file, partPayloadBytes: 20) }
  }

  @Test("should give the same tag, boundaries and names for the same input and key")
  func shouldBeDeterministic() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    var generator = SeededGenerator(seed: 0xDE7E)
    let file = try Self.file(CodecFixtures.lines(&generator, count: 50, maxLength: 70))
    let first = try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: 700)
    let second = try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: 700)
    #expect(first.map(\.key) == second.map(\.key))
    #expect(first.map(\.tag) == second.map(\.tag))
    #expect(zip(first, second).allSatisfy { $0.data != $1.data })
    #expect(try BaseCodec.partPayloads(of: file, partPayloadBytes: 700) == BaseCodec.partPayloads(of: file, partPayloadBytes: 700))
    #expect(try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: 1400).first?.tag == first.first?.tag)
  }

  @Test("should report every missing part by number")
  func shouldReportMissingParts() throws {
    let key = try CodecFixtures.key()
    var generator = SeededGenerator(seed: 0x0155)
    let file = try Self.file(CodecFixtures.lines(&generator, count: 40, maxLength: 60))
    let parts = try Self.open(try BaseCodec.seal(file, vault: try CodecFixtures.vault(), with: key, partPayloadBytes: 500), keys: CodecFixtures.ring(key))
    try #require(parts.count >= 4)
    #expect(throws: VaultCodecError.incomplete(missing: [2])) { try BaseCodec.assemble(parts.filter { $0.part != 2 }, keys: CodecFixtures.ring(key)) }
    #expect(throws: VaultCodecError.incomplete(missing: [1, parts.count])) {
      try BaseCodec.assemble(parts.filter { $0.part != 1 && $0.part != parts.count }, keys: CodecFixtures.ring(key))
    }
    #expect(throws: VaultCodecError.incomplete(missing: [])) { try BaseCodec.assemble([], keys: CodecFixtures.ring(key)) }
  }

  @Test("should reject duplicated parts, parts of another base, mixed keys and mismatched totals")
  func shouldRejectInconsistentParts() throws {
    let key = try CodecFixtures.key()
    let other = try CodecFixtures.key(id: "01936f3e-0000-7000-8000-000000000002", byte: 0x02)
    let vault = try CodecFixtures.vault()
    var generator = SeededGenerator(seed: 0x1C0)
    let lines = CodecFixtures.lines(&generator, count: 30, maxLength: 60)
    let parts = try Self.open(try BaseCodec.seal(try Self.file(lines), vault: vault, with: key, partPayloadBytes: 500), keys: CodecFixtures.ring(key))
    let otherBase = try Self.open(try BaseCodec.seal(try Self.file(Array(lines.dropLast())), vault: vault, with: key, partPayloadBytes: 500), keys: CodecFixtures.ring(key))
    let otherKey = try Self.open(try BaseCodec.seal(try Self.file(lines), vault: vault, with: other, partPayloadBytes: 500), keys: CodecFixtures.ring(other))
    try #require(parts.count >= 3 && otherBase.count == parts.count && otherKey.count == parts.count)
    let ring = CodecFixtures.ring(key, other)

    func expectInconsistent(_ candidate: [BasePart]) {
      let error = CodecFixtures.codecError { _ = try BaseCodec.assemble(candidate, keys: ring) }
      guard case .inconsistentParts? = error else {
        Issue.record("expected inconsistent parts, got \(String(describing: error))")
        return
      }
    }

    expectInconsistent(parts + [parts[0]])
    expectInconsistent([otherBase[0]] + parts.dropFirst())
    expectInconsistent([otherKey[0]] + parts.dropFirst())
    let foreignKeyID = try #require(KeyID("01936f3e-0000-7000-8000-0000000000ff"))
    let reference = parts[0]
    let mixedKey = BasePart(
      header: reference.header,
      tag: reference.tag,
      keyID: foreignKeyID,
      part: reference.part,
      parts: reference.parts,
      totalLines: reference.totalLines,
      lines: reference.lines
    )
    expectInconsistent([mixedKey] + parts.dropFirst())
    let wrongTotal = BasePart(
      header: reference.header,
      tag: reference.tag,
      keyID: reference.keyID,
      part: reference.part,
      parts: reference.parts,
      totalLines: reference.totalLines + 1,
      lines: reference.lines
    )
    expectInconsistent([wrongTotal] + parts.dropFirst())
    let allWrongTotals = parts.map {
      BasePart(header: $0.header, tag: $0.tag, keyID: $0.keyID, part: $0.part, parts: $0.parts, totalLines: $0.totalLines + 1, lines: $0.lines)
    }
    expectInconsistent(allWrongTotals)
    #expect(try BaseCodec.assemble(otherKey, keys: ring) == Self.file(lines))
  }

  @Test("should fail authentication when a part is moved to another part number or another base directory")
  func shouldRejectMovedParts() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    var generator = SeededGenerator(seed: 0x30FE)
    let file = try Self.file(CodecFixtures.lines(&generator, count: 30, maxLength: 60))
    let sealed = try BaseCodec.seal(file, vault: vault, with: key, partPayloadBytes: 500)
    try #require(sealed.count >= 2)
    let moves = [
      VaultPath.basePart(file.header.replica, upTo: file.header.upTo, tag: sealed[0].tag, part: 2, parts: sealed.count),
      VaultPath.basePart(file.header.replica, upTo: file.header.upTo, tag: try CodecFixtures.tag(Self.throughTag), part: 1, parts: sealed.count),
      VaultPath.basePart(file.header.replica, upTo: file.header.upTo + 1, tag: sealed[0].tag, part: 1, parts: sealed.count),
      VaultPath.basePart(file.header.replica, upTo: file.header.upTo, tag: sealed[0].tag, part: 1, parts: sealed.count + 1),
    ]
    for moved in moves {
      #expect(throws: VaultCodecError.file(.authenticationFailed)) { try BaseCodec.openPart(sealed[0].data, at: moved, vault: vault, keys: CodecFixtures.ring(key)) }
    }
    #expect(throws: VaultCodecError.pathMismatch) {
      try BaseCodec.openPart(sealed[0].data, at: VaultPath.manifest(file.header.replica), vault: vault, keys: CodecFixtures.ring(key))
    }
  }

  @Test("should reject a key the ring no longer holds when assembling")
  func shouldRequireKeyToAssemble() throws {
    let key = try CodecFixtures.key()
    let parts = try Self.open(try BaseCodec.seal(try Self.file([Data("a".utf8)]), vault: try CodecFixtures.vault(), with: key), keys: CodecFixtures.ring(key))
    #expect(throws: VaultCodecError.file(.keyUnavailable(key.id))) { try BaseCodec.assemble(parts, keys: { _ in nil }) }
  }

  @Test("should enforce the base header rules in the initialiser")
  func shouldEnforceHeaderRules() throws {
    let replica = try CodecFixtures.replica(Self.replica)
    let tag = try CodecFixtures.tag(Self.throughTag)
    #expect(BaseHeader(replica: replica, upTo: 0, through: nil, schema: 0) != nil)
    #expect(BaseHeader(replica: replica, upTo: 5, through: StreamPoint(last: 5, tag: tag), schema: 0) != nil)
    #expect(BaseHeader(replica: replica, upTo: 999_999_999_999, through: nil, schema: 0) != nil)
    #expect(BaseHeader(replica: replica, upTo: -1, through: nil, schema: 0) == nil)
    #expect(BaseHeader(replica: replica, upTo: 1_000_000_000_000, through: nil, schema: 0) == nil)
    #expect(BaseHeader(replica: replica, upTo: 5, through: StreamPoint(last: 6, tag: tag), schema: 0) == nil)
    #expect(BaseHeader(replica: replica, upTo: 0, through: StreamPoint(last: 0, tag: tag), schema: 0) == nil)
    #expect(BaseHeader(replica: replica, upTo: 5, through: nil, schema: -1) == nil)
    #expect(BaseFile(header: try Self.header(), lines: [Data()]) == nil)
    #expect(BaseFile(header: try Self.header(), lines: [Data("a\nb".utf8)]) == nil)
  }
}
