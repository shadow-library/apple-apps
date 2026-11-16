import Foundation
import ShadowSync
import Testing

@Suite("ObjectKey")
struct ObjectKeyTests {
  static let valid: [String] = [
    "a", "a/b", ".hidden", "a..b", "a.", "...", "A-Z_0.9", "dir/sub/file.bin", "..e/e..", "-", "_", String(repeating: "k", count: 512),
  ]

  static let invalid: [String] = [
    "", "/", "a/", "/a", "a//b", ".", "..", "a/./b", "a/../b", "./a", "a/..", "a b", "caf\u{00E9}", "a+b", "a\\b", "a:b", "a\0b", "a\n", "\u{1F600}",
    "a\u{0301}", String(repeating: "k", count: 513),
  ]

  @Test("should accept valid keys", arguments: valid)
  func shouldAcceptValidKeys(raw: String) {
    #expect(ObjectKey(raw)?.rawValue == raw)
  }

  @Test("should reject invalid keys", arguments: invalid)
  func shouldRejectInvalidKeys(raw: String) {
    #expect(ObjectKey(raw) == nil)
  }

  @Test("should order keys by the bytes of the raw value")
  func shouldOrderByBytes() throws {
    let raws = ["Z", "a", "a.b", "a/b", "a0", "_", "-", "B"]
    let keys = try raws.map { try #require(ObjectKey($0)) }
    #expect(keys.sorted().map(\.rawValue) == ["-", "B", "Z", "_", "a", "a.b", "a/b", "a0"])
  }

  @Test("should round trip through Codable and reject an invalid decoded key")
  func shouldRoundTripCodable() throws {
    let key = try #require(ObjectKey("a/b.c"))
    let data = try JSONEncoder().encode([key])
    #expect(try JSONDecoder().decode([ObjectKey].self, from: data) == [key])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([ObjectKey].self, from: Data(#"["a//b"]"#.utf8)) }
  }

  @Test("should match prefixes by bytes")
  func shouldMatchPrefixes() throws {
    let key = try #require(ObjectKey("abc/def"))
    #expect(key.hasPrefix(""))
    #expect(key.hasPrefix("ab"))
    #expect(key.hasPrefix("abc/def"))
    #expect(!key.hasPrefix("abc/defg"))
    #expect(!key.hasPrefix("b"))
  }
}
