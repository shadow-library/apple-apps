import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("BaseCodec rejection")
struct BaseCodecRejectionTests {
  static let replica = BaseCodecTests.replica
  static let otherReplica = "01936f3e-3333-7333-8333-333333333333"
  static let throughTag = BaseCodecTests.throughTag
  static let directoryTag = "00112233445566778899aabbccddeeff"
  static let through = "{\"last\":9,\"tag\":\"\(throughTag)\"}"
  static let validHeader =
    "{\"count\":2,\"format\":1,\"kind\":\"base\",\"lines\":2,\"part\":1,\"parts\":1,\"replica\":\"\(replica)\",\"schema\":0,\"through\":\(through),\"upto\":12}"
  static let validLogical = "{\"format\":1,\"kind\":\"base\",\"lines\":2,\"replica\":\"\(replica)\",\"schema\":0,\"through\":\(through),\"upto\":12}\na\nb\n"

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

  static func path(tag: String = directoryTag) throws -> ObjectKey {
    VaultPath.basePart(try CodecFixtures.replica(replica), upTo: 12, tag: try CodecFixtures.tag(tag), part: 1, parts: 1)
  }

  static func openError(_ sealed: Data, at key: ObjectKey, payloadLimit: Int = BaseCodec.maximumPartPayloadBytes, lineLimit: Int = BaseCodec.maximumLineCount) throws
    -> VaultCodecError
  {
    let ring = CodecFixtures.ring(try CodecFixtures.key())
    let vault = try CodecFixtures.vault()
    let error = CodecFixtures.codecError {
      _ = try BaseCodec.openPart(sealed, at: key, vault: vault, keys: ring, payloadLimit: payloadLimit, lineLimit: lineLimit)
    }
    return try #require(error)
  }

  static let cases: [Case] = [
    Case(name: "count greater than lines", payload: header([("\"count\":2", "\"count\":3")]) + "\na\nb\nc\n", expected: .malformed),
    Case(name: "count above the real lines", payload: header([("\"count\":2", "\"count\":3"), ("\"lines\":2", "\"lines\":5")]) + "\na\nb\n", expected: .malformed),
    Case(name: "count below the real lines", payload: header([("\"lines\":2", "\"lines\":5")]) + "\na\nb\nc\n", expected: .malformed),
    Case(name: "part zero", payload: header([("\"part\":1", "\"part\":0")]) + "\na\nb\n", expected: .malformed),
    Case(name: "negative part", payload: header([("\"part\":1", "\"part\":-1")]) + "\na\nb\n", expected: .malformed),
    Case(name: "parts zero", payload: header([("\"parts\":1", "\"parts\":0")]) + "\na\nb\n", expected: .malformed),
    Case(name: "part above parts", payload: header([("\"part\":1", "\"part\":2")]) + "\na\nb\n", expected: .malformed),
    Case(name: "parts above the maximum", payload: header([("\"parts\":1", "\"parts\":10000")]) + "\na\nb\n", expected: .malformed),
    Case(
      name: "header part disagrees with the path",
      payload: header([("\"part\":1", "\"part\":2"), ("\"parts\":1", "\"parts\":2")]) + "\na\nb\n",
      expected: .error(.pathMismatch)
    ),
    Case(name: "header parts disagree with the path", payload: header([("\"parts\":1", "\"parts\":2")]) + "\na\nb\n", expected: .error(.pathMismatch)),
    Case(name: "header upto disagrees with the path", payload: header([("\"upto\":12", "\"upto\":13")]) + "\na\nb\n", expected: .error(.pathMismatch)),
    Case(name: "header replica disagrees with the path", payload: header([(replica, otherReplica)]) + "\na\nb\n", expected: .error(.pathMismatch)),
    Case(name: "format 2", payload: header([("\"format\":1", "\"format\":2")]) + "\na\nb\n", expected: .error(.unsupportedFormat(2))),
    Case(name: "kind segment", payload: header([("\"kind\":\"base\"", "\"kind\":\"segment\"")]) + "\na\nb\n", expected: .malformed),
    Case(name: "extra spaces", payload: header([("\"count\":2", "\"count\": 2")]) + "\na\nb\n", expected: .malformed),
    Case(name: "reordered members", payload: header([("{\"count\":2,\"format\":1,", "{\"format\":1,\"count\":2,")]) + "\na\nb\n", expected: .malformed),
    Case(name: "extra member", payload: header([("\"upto\":12}", "\"upto\":12,\"zzz\":1}")]) + "\na\nb\n", expected: .malformed),
    Case(name: "missing member", payload: header([(",\"schema\":0", "")]) + "\na\nb\n", expected: .malformed),
    Case(name: "missing part count", payload: header([("{\"count\":2,", "{")]) + "\na\nb\n", expected: .malformed),
    Case(name: "duplicate member", payload: header([("\"upto\":12}", "\"upto\":12,\"upto\":12}")]) + "\na\nb\n", expected: .malformed),
    Case(name: "segment members", payload: header([("\"through\":", "\"prev\":")]) + "\na\nb\n", expected: .malformed),
    Case(name: "through beyond upto", payload: header([("\"last\":9", "\"last\":13")]) + "\na\nb\n", expected: .malformed),
    Case(name: "through at sequence zero", payload: header([("\"last\":9", "\"last\":0")]) + "\na\nb\n", expected: .malformed),
    Case(name: "through not a point", payload: header([(through, "9")]) + "\na\nb\n", expected: .malformed),
    Case(name: "negative upto", payload: header([("\"upto\":12", "\"upto\":-1")]) + "\na\nb\n", expected: .malformed),
    Case(name: "negative schema", payload: header([("\"schema\":0", "\"schema\":-1")]) + "\na\nb\n", expected: .malformed),
    Case(name: "empty line", payload: validHeader + "\na\n\n", expected: .malformed),
    Case(name: "missing final newline", payload: validHeader + "\na\nb", expected: .malformed),
    Case(name: "empty payload", payload: "", expected: .malformed),
    Case(name: "header not JSON", payload: "base\na\nb\n", expected: .malformed),
  ]

  static let numberSpellings = SegmentCodecRejectionTests.numberSpellings

  @Test("should reject a hand-made part payload that breaks a header or line rule", arguments: cases)
  func shouldRejectHandMadePart(testCase: Case) throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let payload = Data(testCase.payload.utf8)
    let objectKey = try Self.path()
    for codec in [CodecFrame.storedCodec, CodecFrame.deflateCodec] where !(payload.isEmpty && codec == CodecFrame.deflateCodec) {
      let error = try Self.openError(try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key, codec: codec), at: objectKey)
      switch testCase.expected {
      case .malformed: #expect(CodecFixtures.isMalformed(error), "\(error)")
      case .error(let expected): #expect(error == expected)
      }
    }
  }

  @Test("should reject a number that is not a canonical Int64 in any numeric member", arguments: numberSpellings)
  func shouldRejectNumberSpellings(spelling: String) throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let members = [("count", 2), ("format", 1), ("lines", 2), ("part", 1), ("parts", 1), ("schema", 0), ("last", 9), ("upto", 12)]
    for (member, value) in members {
      let payload = Data((Self.header([("\"\(member)\":\(value)", "\"\(member)\":\(spelling)")]) + "\na\nb\n").utf8)
      let objectKey = try Self.path()
      let error = try Self.openError(try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key), at: objectKey)
      #expect(CodecFixtures.isMalformed(error), "\(member) \(value) as \(spelling): \(error)")
    }
  }

  @Test("should accept the valid hand-made part, stored or deflated, and assemble it when the directory carries its tag")
  func shouldAcceptValidHandMadePart() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let tag = ContentTag.make(for: Data(Self.validLogical.utf8), key: key)
    let objectKey = try Self.path(tag: tag.description)
    for codec in [CodecFrame.storedCodec, CodecFrame.deflateCodec] {
      let sealed = try CodecFixtures.sealPayload(Data((Self.validHeader + "\na\nb\n").utf8), at: objectKey, vault: vault, with: key, codec: codec)
      let part = try BaseCodec.openPart(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key))
      #expect(part.lines == [Data("a".utf8), Data("b".utf8)])
      #expect(try BaseCodec.assemble([part], keys: CodecFixtures.ring(key)).lines == part.lines)
    }
  }

  @Test("should open a valid part whose directory carries another tag and report the tag error when assembling")
  func shouldRejectWrongDirectoryTagAtAssembly() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = try Self.path()
    let sealed = try CodecFixtures.sealPayload(Data((Self.validHeader + "\na\nb\n").utf8), at: objectKey, vault: vault, with: key)
    let part = try BaseCodec.openPart(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key))
    #expect(part.tag.description == Self.directoryTag)
    #expect(throws: VaultCodecError.tagMismatch) { try BaseCodec.assemble([part], keys: CodecFixtures.ring(key)) }
  }

  @Test("should reject an unknown codec byte, an empty body and a truncated DEFLATE body")
  func shouldRejectBodies() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = try Self.path()
    let payload = Data((Self.validHeader + "\na\nb\n").utf8)
    for codec: UInt8 in [2, 0xFF] {
      let sealed = try CodecFixtures.sealBody(Data([codec]) + payload, at: objectKey, vault: vault, with: key)
      #expect(try Self.openError(sealed, at: objectKey) == .unsupportedCodec(codec))
    }
    #expect(CodecFixtures.isMalformed(try Self.openError(try CodecFixtures.sealBody(Data(), at: objectKey, vault: vault, with: key), at: objectKey)))
    let deflated = try #require(CodecDeflate.deflate(payload, capacity: payload.count))
    for body in [deflated.prefix(deflated.count / 2), deflated.prefix(1), Data([0xFF, 0xFF, 0xFF])] {
      let sealed = try CodecFixtures.sealBody(Data([CodecFrame.deflateCodec]) + body, at: objectKey, vault: vault, with: key)
      #expect(CodecFixtures.isMalformed(try Self.openError(sealed, at: objectKey)))
    }
  }

  @Test("should reject oversized stored and deflated bodies at the payload limit")
  func shouldRejectOversizedBodies() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = try Self.path()
    let stored = try CodecFixtures.sealBody(Data([CodecFrame.storedCodec]) + Data(count: 4097), at: objectKey, vault: vault, with: key)
    #expect(try Self.openError(stored, at: objectKey, payloadLimit: 4096) == .payloadTooLarge)
    let bomb = try #require(CodecDeflate.deflate(Data(count: 1024 * 1024), capacity: 64 * 1024))
    let deflated = try CodecFixtures.sealBody(Data([CodecFrame.deflateCodec]) + bomb, at: objectKey, vault: vault, with: key)
    #expect(try Self.openError(deflated, at: objectKey, payloadLimit: 4096) == .payloadTooLarge)
    let valid = try CodecFixtures.sealPayload(Data((Self.validHeader + "\na\nb\n").utf8), at: objectKey, vault: vault, with: key)
    #expect(try Self.openError(valid, at: objectKey, payloadLimit: 16) == .payloadTooLarge)
  }

  @Test("should reject a part whose count exceeds the line limit before splitting lines")
  func shouldRejectCountAboveLineLimit() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    let objectKey = try Self.path()
    let huge = BaseCodec.maximumLineCount + 1
    let payload = Data((Self.header([("\"count\":2", "\"count\":\(huge)"), ("\"lines\":2", "\"lines\":\(huge)")]) + "\na\n").utf8)
    let sealed = try CodecFixtures.sealPayload(payload, at: objectKey, vault: vault, with: key)
    #expect(try Self.openError(sealed, at: objectKey) == .malformed("more lines than a file may hold"))
    let valid = try CodecFixtures.sealPayload(Data((Self.validHeader + "\na\nb\n").utf8), at: objectKey, vault: vault, with: key)
    #expect(try Self.openError(valid, at: objectKey, lineLimit: 1) == .malformed("more lines than a file may hold"))
    #expect(try BaseCodec.openPart(valid, at: objectKey, vault: vault, keys: CodecFixtures.ring(key), payloadLimit: 1024, lineLimit: 2).lines.count == 2)
  }

  @Test("should never trap on random or mutated contents of an authentic part")
  func shouldNotTrapOnAuthenticContents() throws {
    let key = try CodecFixtures.key()
    let vault = try CodecFixtures.vault()
    try forAll(iterations: 300) { generator in
      let upTo = Int64(generator.int(in: 0...1000))
      let header = try #require(BaseHeader(replica: try CodecFixtures.replica(&generator), upTo: upTo, through: nil, schema: generator.int(in: 0...5)))
      let file = try #require(BaseFile(header: header, lines: CodecFixtures.lines(&generator, count: generator.int(in: 0...30), maxLength: 50)))
      let payloads = try BaseCodec.partPayloads(of: file, partPayloadBytes: 600)
      let index = generator.int(in: 0...(payloads.count - 1))
      var body = CodecFrame.body(of: payloads[index])
      switch generator.int(in: 0...3) {
      case 0:
        body = generator.data(count: generator.int(in: 0...300))
      case 1:
        body = body.prefix(generator.int(in: 0...body.count))
      case 2:
        for _ in 0..<generator.int(in: 1...4) {
          let position = generator.int(in: 0...(body.count - 1))
          body[position] = UInt8(truncatingIfNeeded: generator.next())
        }
      default:
        body.insert(generator.pick(from: [0x0A, 0x00, 0x22, 0x2C, 0x7D]), at: generator.int(in: 1...body.count))
      }
      let tag = try CodecFixtures.tag(&generator)
      let objectKey = VaultPath.basePart(header.replica, upTo: upTo, tag: tag, part: index + 1, parts: payloads.count)
      let sealed = try CodecFixtures.sealBody(body, at: objectKey, vault: vault, with: key)
      guard let part = try? BaseCodec.openPart(sealed, at: objectKey, vault: vault, keys: CodecFixtures.ring(key)) else { return }
      _ = try? BaseCodec.assemble([part], keys: CodecFixtures.ring(key))
    }
  }
}
