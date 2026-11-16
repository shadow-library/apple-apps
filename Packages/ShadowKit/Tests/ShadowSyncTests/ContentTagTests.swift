import CryptoKit
import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("ContentTag")
struct ContentTagTests {
  static let knownPayload = Data("{\"a\":1}\n".utf8)
  static let knownTag = "e6ef39ba0ef6c750c7d4d9f52e3e2bb5"

  static let valid = ["0123456789abcdef0123456789abcdef", String(repeating: "0", count: 32), String(repeating: "f", count: 32)]

  static let invalid = [
    "", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0", "0123456789ABCDEF0123456789abcdef", "0123456789abcdef0123456789abcdeg",
    " 123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcde\u{00E9}", "0123456789abcdef-123456789abcdef",
  ]

  @Test("should match the pinned known answer rebuilt from CryptoKit primitives")
  func shouldMatchKnownAnswer() throws {
    let key = try CodecFixtures.key()
    let ringKey = SymmetricKey(data: Data(repeating: 0x42, count: 32))
    let tagKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: ringKey, salt: Data(), info: Data("SLV1/content-tag".utf8), outputByteCount: 32)
    let mac = HMAC<SHA256>.authenticationCode(for: Self.knownPayload, using: tagKey)
    let expected = Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    #expect(ContentTag.make(for: Self.knownPayload, key: key).description == expected)
    #expect(expected == Self.knownTag)
  }

  @Test("should equal the tag computed over framed lines")
  func shouldEqualTagOverLines() throws {
    let key = try CodecFixtures.key()
    let lines = [Data("header".utf8), Data("one".utf8), Data("two".utf8)]
    #expect(ContentTag.make(lines: lines, key: key) == ContentTag.make(for: Data("header\none\ntwo\n".utf8), key: key))
  }

  @Test("should differ for different keys and different payloads")
  func shouldDifferForKeysAndPayloads() throws {
    let key = try CodecFixtures.key()
    let other = try CodecFixtures.key(byte: 0x43)
    let tag = ContentTag.make(for: Self.knownPayload, key: key)
    #expect(ContentTag.make(for: Self.knownPayload, key: other) != tag)
    #expect(ContentTag.make(for: Data("{\"a\":2}\n".utf8), key: key) != tag)
    #expect(ContentTag.make(for: Self.knownPayload, key: key) == tag)
  }

  @Test("should not depend on the key id, only on the key bytes")
  func shouldIgnoreKeyID() throws {
    let key = try CodecFixtures.key()
    let renamed = try CodecFixtures.key(id: "01936f3e-0000-7000-8000-000000000002")
    #expect(ContentTag.make(for: Self.knownPayload, key: key) == ContentTag.make(for: Self.knownPayload, key: renamed))
  }

  @Test("should accept canonical tag text", arguments: valid)
  func shouldAcceptValidText(text: String) {
    #expect(ContentTag(text)?.description == text)
  }

  @Test("should reject non-canonical tag text", arguments: invalid)
  func shouldRejectInvalidText(text: String) {
    #expect(ContentTag(text) == nil)
  }

  @Test("should round trip through Codable as a bare string and reject invalid text")
  func shouldRoundTripCodable() throws {
    let tag = try CodecFixtures.tag("0123456789abcdef0123456789abcdef")
    let data = try JSONEncoder().encode([tag])
    #expect(String(decoding: data, as: UTF8.self) == "[\"0123456789abcdef0123456789abcdef\"]")
    #expect(try JSONDecoder().decode([ContentTag].self, from: data) == [tag])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([ContentTag].self, from: Data("[\"0123456789ABCDEF0123456789abcdef\"]".utf8)) }
  }

  @Test("should order stream points by last, then by tag")
  func shouldOrderStreamPoints() throws {
    let low = try CodecFixtures.tag(String(repeating: "0", count: 32))
    let high = try CodecFixtures.tag(String(repeating: "f", count: 32))
    let points = [StreamPoint(last: 2, tag: low), StreamPoint(last: 1, tag: high), StreamPoint(last: 2, tag: high), StreamPoint(last: 1, tag: low)]
    #expect(points.sorted() == [StreamPoint(last: 1, tag: low), StreamPoint(last: 1, tag: high), StreamPoint(last: 2, tag: low), StreamPoint(last: 2, tag: high)])
  }

  @Test("should round trip a stream point through Codable")
  func shouldRoundTripStreamPoint() throws {
    let point = StreamPoint(last: 7, tag: try CodecFixtures.tag("0123456789abcdef0123456789abcdef"))
    #expect(try JSONDecoder().decode(StreamPoint.self, from: JSONEncoder().encode(point)) == point)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(StreamPoint.self, from: Data("{\"last\":7,\"tag\":\"nope\"}".utf8)) }
  }
}
