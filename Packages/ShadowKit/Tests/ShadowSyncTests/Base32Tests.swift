import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Base32")
struct Base32Tests {
  @Test(
    "should match the RFC 4648 vectors without padding",
    arguments: [("", ""), ("f", "MY"), ("fo", "MZXQ"), ("foo", "MZXW6"), ("foob", "MZXW6YQ"), ("fooba", "MZXW6YTB"), ("foobar", "MZXW6YTBOI")])
  func shouldMatchVectors(plain: String, encoded: String) {
    #expect(Base32.encode(Array(plain.utf8)) == encoded)
    #expect(Base32.decode(Array(encoded.utf8)) == Array(plain.utf8))
  }

  @Test("should reject lower case, padding, invalid characters, impossible lengths and non-zero trailing bits")
  func shouldRejectNonCanonicalText() {
    for text in ["my", "Mzxw6", "MY======", "MZXW6===", "MY=", "M1", "MZ XQ", "MZXQ\n", "M", "MZX", "MZXW6Y", "MZ", "MZXR", "MZXW7", "MZXW6YR", "MZXW6YTBOJ", "M\u{0}"] {
      #expect(Base32.decode(Array(text.utf8)) == nil, "\(text)")
    }
  }

  @Test("should round-trip random bytes using only A-Z and 2-7")
  func shouldRoundTripRandomBytes() throws {
    try forAll(iterations: 300) { generator in
      let bytes = Array(generator.data(count: generator.int(in: 0...120)))
      let encoded = Base32.encode(bytes)
      #expect(encoded.utf8.count == (bytes.count * 8 + 4) / 5)
      #expect(encoded.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) })
      #expect(Base32.decode(Array(encoded.utf8)) == bytes)
    }
  }
}
