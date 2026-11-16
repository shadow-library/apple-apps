import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("SegmentCodec rejection")
struct SegmentCodecRejectionTests {
  static let replica = SegmentCodecTests.replica
  static let tag = SegmentCodecTests.previousTag
  static let prev = "{\"last\":4,\"tag\":\"\(tag)\"}"
  static let validHeader = "{\"count\":2,\"deps\":{},\"first\":5,\"format\":1,\"kind\":\"segment\",\"last\":6,\"prev\":\(prev),\"replica\":\"\(replica)\",\"schema\":0}"

  struct Case: CustomTestStringConvertible, Sendable {
    let name: String
    let payload: String
    let expected: Expected

    var testDescription: String { name }
  }

  enum Expected: Sendable, Equatable {
    case malformed
    case error(VaultCodecError)
  }

  static func header(_ replacements: [(String, String)]) -> String {
    replacements.reduce(validHeader) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
  }

  static let cases: [Case] = [
    Case(name: "count mismatch", payload: header([("\"count\":2", "\"count\":3")]) + "\na\nb\n", expected: .malformed),
    Case(name: "missing member", payload: header([(",\"schema\":0", "")]) + "\na\nb\n", expected: .malformed),
    Case(name: "extra member", payload: header([("\"schema\":0}", "\"schema\":0,\"zzz\":1}")]) + "\na\nb\n", expected: .malformed),
    Case(name: "reordered members", payload: header([("{\"count\":2,\"deps\":{},\"first\":5,", "{\"first\":5,\"count\":2,\"deps\":{},")]) + "\na\nb\n", expected: .malformed),
    Case(name: "extra spaces", payload: header([("\"count\":2", "\"count\": 2")]) + "\na\nb\n", expected: .malformed),
    Case(name: "leading space", payload: " " + validHeader + "\na\nb\n", expected: .malformed),
    Case(name: "escaped but equal string", payload: header([("\"kind\":\"segment\"", "\"kind\":\"segm\\u0065nt\"")]) + "\na\nb\n", expected: .malformed),
    Case(name: "duplicate member", payload: header([("\"schema\":0}", "\"schema\":0,\"schema\":0}")]) + "\na\nb\n", expected: .malformed),
    Case(name: "format 2", payload: header([("\"format\":1", "\"format\":2")]) + "\na\nb\n", expected: .error(.unsupportedFormat(2))),
    Case(name: "format 2 with other members", payload: "{\"format\":2,\"whatever\":true}\na\n", expected: .error(.unsupportedFormat(2))),
    Case(name: "format as string", payload: header([("\"format\":1", "\"format\":\"1\"")]) + "\na\nb\n", expected: .malformed),
    Case(name: "kind base", payload: header([("\"kind\":\"segment\"", "\"kind\":\"base\"")]) + "\na\nb\n", expected: .malformed),
    Case(name: "empty line", payload: validHeader + "\na\n\nb\n", expected: .malformed),
    Case(name: "empty last line", payload: validHeader + "\na\n\n", expected: .malformed),
    Case(name: "missing final newline", payload: validHeader + "\na\nb", expected: .malformed),
    Case(name: "more lines than counted", payload: validHeader + "\na\nb\nc\n", expected: .malformed),
    Case(name: "fewer lines than counted", payload: validHeader + "\na\n", expected: .malformed),
    Case(name: "no lines and no newline after the header", payload: validHeader, expected: .malformed),
    Case(name: "empty payload", payload: "", expected: .malformed),
    Case(name: "empty header line", payload: "\na\nb\n", expected: .malformed),
    Case(name: "header not JSON", payload: "segment\na\nb\n", expected: .malformed),
    Case(name: "header an array", payload: "[1]\na\nb\n", expected: .malformed),
    Case(name: "missing previous", payload: header([("\"prev\":\(prev)", "\"prev\":null")]) + "\na\nb\n", expected: .malformed),
    Case(name: "previous does not precede first", payload: header([("\"last\":4,", "\"last\":3,")]) + "\na\nb\n", expected: .malformed),
    Case(name: "previous with an invalid tag", payload: header([(tag, tag.uppercased())]) + "\na\nb\n", expected: .malformed),
    Case(name: "previous with an extra member", payload: header([("\"last\":4,", "\"a\":0,\"last\":4,")]) + "\na\nb\n", expected: .malformed),
    Case(name: "dependency on itself", payload: header([("\"deps\":{}", "\"deps\":{\"\(replica)\":\(prev)}")]) + "\na\nb\n", expected: .malformed),
    Case(name: "dependency on a non-canonical replica id", payload: header([("\"deps\":{}", "\"deps\":{\"\(replica.uppercased())\":\(prev)}")]) + "\na\nb\n", expected: .malformed),
    Case(
      name: "dependency at sequence zero",
      payload: header([("\"deps\":{}", "\"deps\":{\"\(SegmentCodecTests.dependency)\":{\"last\":0,\"tag\":\"\(tag)\"}}")]) + "\na\nb\n",
      expected: .malformed
    ),
    Case(name: "negative schema", payload: header([("\"schema\":0", "\"schema\":-1")]) + "\na\nb\n", expected: .malformed),
    Case(name: "replica not a string", payload: header([("\"replica\":\"\(replica)\"", "\"replica\":1")]) + "\na\nb\n", expected: .malformed),
    Case(name: "first beyond twelve digits", payload: header([("\"first\":5", "\"first\":9223372036854775807")]) + "\na\nb\n", expected: .malformed),
  ]

  @Test("should reject a hand-made payload that breaks a header or line rule", arguments: cases)
  func shouldRejectHandMadePayload(testCase: Case) throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data(testCase.payload.utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: key))
    for codec in [CodecFrame.storedCodec, CodecFrame.deflateCodec] where !(payload.isEmpty && codec == CodecFrame.deflateCodec) {
      let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key, codec: codec)
      let error = try #require(CodecFixtures.codecError { _ = try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) })
      switch testCase.expected {
      case .malformed: #expect(CodecFixtures.isMalformed(error), "\(error)")
      case .error(let expected): #expect(error == expected)
      }
    }
  }

  static let numberSpellings = ["2.0", "02", "2e0", "2E0", "-0", "1e400", "9223372036854775808", "-9223372036854775809", "18446744073709551616", "+2", "0x2", "\"2\""]

  @Test("should reject a number that is not a canonical Int64 in any numeric member", arguments: numberSpellings)
  func shouldRejectNumberSpellings(spelling: String) throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    for (member, value) in [("count", 2), ("first", 5), ("last", 6), ("format", 1), ("schema", 0), ("last", 4)] {
      let payload = Data((Self.header([("\"\(member)\":\(value)", "\"\(member)\":\(spelling)")]) + "\na\nb\n").utf8)
      let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: key))
      let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
      let error = try #require(CodecFixtures.codecError { _ = try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) })
      #expect(CodecFixtures.isMalformed(error), "\(member) \(value) as \(spelling): \(error)")
    }
  }

  @Test("should reject a count above the line limit before splitting lines")
  func shouldRejectCountAboveLineLimit() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let replica = try CodecFixtures.replica(Self.replica)
    let huge = SegmentCodec.maximumLineCount + 1
    let header = "{\"count\":\(huge),\"deps\":{},\"first\":1,\"format\":1,\"kind\":\"segment\",\"last\":\(huge),\"prev\":null,\"replica\":\"\(Self.replica)\",\"schema\":0}"
    let payload = Data((header + "\na\n").utf8)
    let objectKey = VaultPath.segment(replica, first: 1, last: Int64(huge), tag: ContentTag.make(for: payload, key: key))
    let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.malformed("more lines than a file may hold")) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }

    let valid = Data((Self.validHeader + "\na\nb\n").utf8)
    let validKey = VaultPath.segment(replica, first: 5, last: 6, tag: ContentTag.make(for: valid, key: key))
    let sealedValid = try CodecFixtures.sealPayload(valid, at: validKey, vault: vault, with: key)
    let limit = SegmentCodec.maximumPayloadBytes
    #expect(throws: VaultCodecError.malformed("more lines than a file may hold")) {
      try SegmentCodec.open(sealedValid, at: validKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: limit, lineLimit: 1)
    }
    #expect(try SegmentCodec.open(sealedValid, at: validKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: limit, lineLimit: 2).lines.count == 2)
  }

  @Test("should accept the valid hand-made payload under its own name, stored or deflated")
  func shouldAcceptValidHandMadePayload() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: key))
    for codec in [CodecFrame.storedCodec, CodecFrame.deflateCodec] {
      let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key, codec: codec)
      let file = try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key))
      #expect(file.lines == [Data("a".utf8), Data("b".utf8)])
      #expect(SegmentCodec.payload(of: file) == payload)
    }
  }

  @Test("should report a tag mismatch for a valid payload whose name carries another tag")
  func shouldRejectWrongTag() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: try CodecFixtures.tag(Self.tag))
    let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.tagMismatch) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }
  }

  @Test("should report a tag mismatch when the tag was computed with another ring key")
  func shouldRejectTagFromOtherKey() throws {
    let key = try CodecFixtures.key()
    let other = try CodecFixtures.key(id: "01936f3e-0000-7000-8000-000000000009", byte: 0x09)
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: other))
    let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.tagMismatch) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key, other)) }
  }

  @Test("should report a path mismatch for a valid payload sealed under another replica, first or last")
  func shouldRejectPathDisagreement() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let tag = ContentTag.make(for: payload, key: key)
    let replica = try CodecFixtures.replica(Self.replica)
    let keys = [
      VaultPath.segment(try CodecFixtures.replica(SegmentCodecTests.dependency), first: 5, last: 6, tag: tag),
      VaultPath.segment(replica, first: 4, last: 6, tag: tag),
      VaultPath.segment(replica, first: 5, last: 7, tag: tag),
    ]
    for objectKey in keys {
      let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
      #expect(throws: VaultCodecError.pathMismatch) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }
    }
  }

  @Test("should reject an unknown codec byte and an empty body")
  func shouldRejectCodecByte() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: key))
    for codec: UInt8 in [2, 0x7B, 0xFF] {
      let sealed = try CodecFixtures.sealBody(Data([codec]) + payload, at: objectKey, vault: vault, with: key)
      #expect(throws: VaultCodecError.unsupportedCodec(codec)) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }
    }
    let empty = try CodecFixtures.sealBody(Data(), at: objectKey, vault: vault, with: key)
    let error = try #require(CodecFixtures.codecError { _ = try SegmentCodec.open(empty, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) })
    #expect(CodecFixtures.isMalformed(error))
  }

  @Test("should reject truncated and invalid DEFLATE bodies")
  func shouldRejectBrokenDeflate() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 5, last: 6, tag: ContentTag.make(for: payload, key: key))
    let deflated = try #require(CodecDeflate.deflate(payload, capacity: payload.count))
    let bodies = [deflated.prefix(deflated.count / 2), deflated.prefix(1), Data([0xFF, 0xFF, 0xFF, 0xFF])]
    for body in bodies {
      let sealed = try CodecFixtures.sealBody(Data([CodecFrame.deflateCodec]) + body, at: objectKey, vault: vault, with: key)
      let error = try #require(CodecFixtures.codecError { _ = try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) })
      #expect(CodecFixtures.isMalformed(error), "\(error)")
    }
  }

  @Test("should stop inflating at the cap")
  func shouldCapInflation() throws {
    let zeros = Data(count: 4 * 1024 * 1024)
    let bomb = try #require(CodecDeflate.deflate(zeros, capacity: zeros.count))
    #expect(bomb.count < 16 * 1024)
    #expect(throws: VaultCodecError.payloadTooLarge) { try CodecDeflate.inflate(bomb, limit: 64 * 1024) }
    #expect(throws: VaultCodecError.payloadTooLarge) { try CodecDeflate.inflate(bomb, limit: zeros.count - 1) }
    #expect(try CodecDeflate.inflate(bomb, limit: zeros.count) == zeros)

    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 1, last: 1, tag: try CodecFixtures.tag(Self.tag))
    let sealed = try CodecFixtures.sealBody(Data([CodecFrame.deflateCodec]) + bomb, at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.payloadTooLarge) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: 64 * 1024) }
    let stored = try CodecFixtures.sealBody(Data([CodecFrame.storedCodec]) + Data(count: 64 * 1024 + 1), at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.payloadTooLarge) { try SegmentCodec.open(stored, at: objectKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: 64 * 1024) }
  }

  @Test("should reject a payload that inflates beyond the public cap")
  func shouldCapInflationAtMaximum() throws {
    let zeros = Data(count: SegmentCodec.maximumPayloadBytes + 1)
    let bomb = try #require(CodecDeflate.deflate(zeros, capacity: 1024 * 1024))
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 1, last: 1, tag: try CodecFixtures.tag(Self.tag))
    let sealed = try CodecFixtures.sealBody(Data([CodecFrame.deflateCodec]) + bomb, at: objectKey, vault: vault, with: key)
    #expect(throws: VaultCodecError.payloadTooLarge) { try SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }
  }

  @Test("should never trap on random bytes")
  func shouldNotTrapOnRandomBytes() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = VaultPath.segment(try CodecFixtures.replica(Self.replica), first: 1, last: 1, tag: try CodecFixtures.tag(Self.tag))
    try forAll(iterations: 300) { generator in
      let data = generator.data(count: generator.int(in: 0...400))
      #expect(throws: VaultCodecError.self) { try SegmentCodec.open(data, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) }
    }
  }

  @Test("should never trap on random or mutated contents of an authentic vault file")
  func shouldNotTrapOnAuthenticContents() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    try forAll(iterations: 300) { generator in
      let file = try CodecFixtures.segment(&generator)
      var body = CodecFrame.body(of: SegmentCodec.payload(of: file))
      switch generator.int(in: 0...3) {
      case 0:
        body = generator.data(count: generator.int(in: 0...300))
      case 1:
        body = body.prefix(generator.int(in: 0...body.count))
      case 2:
        for _ in 0..<generator.int(in: 1...4) {
          let index = generator.int(in: 0...(body.count - 1))
          body[index] = UInt8(truncatingIfNeeded: generator.next())
        }
      default:
        body.insert(generator.pick(from: [0x0A, 0x00, 0x22, 0x7D]), at: generator.int(in: 1...body.count))
      }
      let objectKey = VaultPath.segment(file.header.replica, first: file.header.first, last: file.header.last, tag: try CodecFixtures.tag(&generator))
      let sealed = try CodecFixtures.sealBody(body, at: objectKey, vault: vault, with: key)
      _ = try? SegmentCodec.open(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key))
    }
  }
}
