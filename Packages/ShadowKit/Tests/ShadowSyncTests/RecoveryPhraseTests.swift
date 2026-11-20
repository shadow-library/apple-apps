import CryptoKit
import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("RecoveryPhrase", TestTimeLimit.quick)
struct RecoveryPhraseTests {
  private static let vectors: [(entropy: String, mnemonic: String)] = [
    (
      "0000000000000000000000000000000000000000000000000000000000000000",
      "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"
    ),
    (
      "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f",
      "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title"
    ),
    (
      "8080808080808080808080808080808080808080808080808080808080808080",
      "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless"
    ),
    (
      "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
      "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote"
    ),
    (
      "68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c",
      "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length"
    ),
    (
      "9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863",
      "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside"
    ),
    (
      "066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad",
      "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform"
    ),
    (
      "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f",
      "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold"
    ),
  ]

  private static let allZero =
    "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art"

  private static func secret(hex text: String) throws -> RecoverySecret {
    let digits = Array(text.utf8)
    try #require(digits.count == RecoverySecret.byteCount * 2)
    let bytes = try stride(from: 0, to: digits.count, by: 2).map { index in
      try #require(UInt8(String(decoding: digits[index...(index + 1)], as: UTF8.self), radix: 16))
    }
    return try #require(RecoverySecret(rawBytes: Data(bytes)))
  }

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  @Test("should encode the official 256-bit vectors to their mnemonics")
  func shouldEncodeOfficialVectors() throws {
    for vector in Self.vectors {
      let phrase = RecoveryPhrase(secret: try Self.secret(hex: vector.entropy))
      #expect(phrase.words.joined(separator: " ") == vector.mnemonic)
    }
  }

  @Test("should decode the official 256-bit mnemonics to their entropy")
  func shouldDecodeOfficialVectors() throws {
    #expect(Self.vectors.count == 8)
    for vector in Self.vectors {
      let phrase = try RecoveryPhrase(parsing: vector.mnemonic)
      #expect(Self.hex(phrase.secret.rawBytes) == vector.entropy)
    }
  }

  @Test("should encode the all-zero and all-ones secrets as the documented edge phrases")
  func shouldEncodeEdgePhrases() throws {
    let zero = RecoveryPhrase(secret: try #require(RecoverySecret(rawBytes: Data(count: 32))))
    #expect(zero.words == Array(repeating: "abandon", count: 23) + ["art"])
    let ones = RecoveryPhrase(secret: try #require(RecoverySecret(rawBytes: Data(repeating: 0xFF, count: 32))))
    #expect(ones.words == Array(repeating: "zoo", count: 23) + ["vote"])
  }

  @Test("should always produce 24 words from the list")
  func shouldProduceTwentyFourWords() {
    let words = RecoveryPhrase(secret: RecoverySecret.generate()).words
    #expect(words.count == RecoveryPhrase.wordCount)
    #expect(words.allSatisfy { RecoveryWordList.words.contains($0) })
  }

  @Test("should reject a phrase whose checksum word is changed")
  func shouldRejectBadChecksum() throws {
    let words = Self.allZero.split(separator: " ").map(String.init)
    let tampered = (words.dropLast() + ["zoo"]).joined(separator: " ")
    #expect(throws: RecoveryPhraseError.badChecksum) { try RecoveryPhrase(parsing: tampered) }
  }

  @Test("should reject two swapped words")
  func shouldRejectSwappedWords() throws {
    var words = try #require(Self.vectors.last).mnemonic.split(separator: " ").map(String.init)
    words.swapAt(0, 1)
    #expect(throws: RecoveryPhraseError.badChecksum) { try RecoveryPhrase(parsing: words.joined(separator: " ")) }
  }

  @Test("should report the position of the first unknown word")
  func shouldRejectUnknownWord() {
    var words = Self.allZero.split(separator: " ").map(String.init)
    words[6] = "abandonn"
    words[9] = "zzzz"
    #expect(throws: RecoveryPhraseError.unknownWord(position: 7)) { try RecoveryPhrase(parsing: words.joined(separator: " ")) }
  }

  @Test("should reject a phrase that is not 24 words long")
  func shouldRejectWrongCount() {
    let words = Self.allZero.split(separator: " ").map(String.init)
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 23)) { try RecoveryPhrase(parsing: words.dropLast().joined(separator: " ")) }
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 25)) { try RecoveryPhrase(parsing: Self.allZero + " abandon") }
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 0)) { try RecoveryPhrase(parsing: "") }
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 0)) { try RecoveryPhrase(parsing: " \n\t ") }
  }

  @Test("should reject a valid 12-word BIP-39 phrase")
  func shouldRejectShortValidPhrase() {
    let twelve = Array(repeating: "abandon", count: 11) + ["about"]
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 12)) { try RecoveryPhrase(parsing: twelve.joined(separator: " ")) }
  }

  @Test("should count words before looking any up")
  func shouldCheckCountBeforeWords() {
    #expect(throws: RecoveryPhraseError.wrongWordCount(found: 2)) { try RecoveryPhrase(parsing: "zzzz yyyy") }
  }

  @Test("should accept uppercase, mixed case and any whitespace between words")
  func shouldNormaliseInput() throws {
    let expected = try Self.secret(hex: "0000000000000000000000000000000000000000000000000000000000000000").rawBytes
    let words = Self.allZero.split(separator: " ").map(String.init)
    let variants = [
      Self.allZero.uppercased(),
      Self.allZero.capitalized,
      "  \(Self.allZero)\n",
      words.joined(separator: "   "),
      words.joined(separator: "\n"),
      words.joined(separator: "\t"),
      words.joined(separator: "\u{00A0}"),
      words.joined(separator: "\u{3000}"),
      words.joined(separator: "\r\n "),
      Self.allZero.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? "",
    ]
    for variant in variants {
      #expect(try RecoveryPhrase(parsing: variant).secret.rawBytes == expected)
    }
  }

  @Test("should compare phrases by their secret")
  func shouldCompareBySecret() throws {
    let first = RecoveryPhrase(secret: try Self.secret(hex: "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f"))
    #expect(first == (try RecoveryPhrase(parsing: first.words.joined(separator: " "))))
    #expect(first != RecoveryPhrase(secret: try Self.secret(hex: "8080808080808080808080808080808080808080808080808080808080808080")))
  }

  @Test("should never print the phrase or its words")
  func shouldRedactPhrase() {
    let phrase = RecoveryPhrase(secret: RecoverySecret.generate())
    let word = phrase.words[0]
    var dumped = ""
    dump(phrase, to: &dumped)
    for rendering in [String(describing: phrase), String(reflecting: phrase), "\(phrase)", dumped] {
      #expect(!rendering.contains(word))
      #expect(!rendering.contains("abandon"))
    }
    #expect(String(describing: phrase) == "RecoveryPhrase(redacted)")
  }

  @Test("should not echo any input word in error messages")
  func shouldKeepErrorsFree() throws {
    let unknown = Array(repeating: "abandon", count: 22) + ["zzzzsecret", "art"]
    let badChecksum = Array(repeating: "zoo", count: 24)
    let wrongCount = ["zzzzsecret", "ability"]
    for words in [unknown, badChecksum, wrongCount] {
      let error = try #require(throws: RecoveryPhraseError.self) { try RecoveryPhrase(parsing: words.joined(separator: " ")) }
      let rendered = [error.errorDescription ?? "", "\(error)", String(reflecting: error)]
      for text in rendered {
        for word in Set(words) { #expect(!text.contains(word)) }
      }
    }
    #expect(RecoveryPhraseError.unknownWord(position: 23).errorDescription?.contains("23") == true)
  }

  @Test("should embed the official BIP-39 English list")
  func shouldPinWordListDigest() {
    let words = RecoveryWordList.words
    #expect(words.count == 2048)
    #expect(Set(words).count == 2048)
    #expect(words == words.sorted())
    let digest = SHA256.hash(data: Data((words.joined(separator: "\n") + "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda")
  }

  @Test("should be uniquely identified by the first four letters of every word")
  func shouldHaveDistinctPrefixes() {
    #expect(Set(RecoveryWordList.words.map { $0.prefix(4) }).count == 2048)
  }
}

@Suite("RecoveryPhrase properties", TestTimeLimit.property)
struct RecoveryPhrasePropertyTests {
  @Test("should round-trip seeded random secrets through their words")
  func shouldRoundTripRandomSecrets() throws {
    try forAll(iterations: 500) { generator in
      let bytes = Data((0..<RecoverySecret.byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
      let secret = try #require(RecoverySecret(rawBytes: bytes))
      let words = RecoveryPhrase(secret: secret).words
      #expect(words.count == RecoveryPhrase.wordCount)
      #expect(try RecoveryPhrase(parsing: words.joined(separator: " ")).secret.rawBytes == bytes)
    }
  }

  private static func checksumHolds(_ words: [String]) -> Bool {
    var bits: [UInt8] = []
    for word in words {
      let index = RecoveryWordList.words.firstIndex(of: word) ?? 0
      for shift in stride(from: 10, through: 0, by: -1) { bits.append(UInt8((index >> shift) & 1)) }
    }
    let bytes = stride(from: 0, to: bits.count, by: 8).map { start in bits[start..<start + 8].reduce(UInt8(0)) { ($0 << 1) | $1 } }
    return Data(SHA256.hash(data: Data(bytes.prefix(32)))).first == bytes[32]
  }

  @Test("should accept a substituted word exactly when the checksum still holds and reproduce it on re-encoding")
  func shouldAcceptSubstitutionsOnlyWhenChecksumHolds() throws {
    var accepted = 0
    var rejected = 0
    try forAll(iterations: 20) { generator in
      let bytes = Data((0..<RecoverySecret.byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) })
      let original = RecoveryPhrase(secret: try #require(RecoverySecret(rawBytes: bytes))).words
      let position = Int.random(in: 0..<original.count, using: &generator)
      for candidate in RecoveryWordList.words where candidate != original[position] {
        var words = original
        words[position] = candidate
        let text = words.joined(separator: " ")
        if Self.checksumHolds(words) {
          accepted += 1
          #expect(try RecoveryPhrase(parsing: text).words == words)
        } else {
          rejected += 1
          #expect(throws: RecoveryPhraseError.badChecksum) { try RecoveryPhrase(parsing: text) }
        }
      }
    }
    #expect(accepted > 0)
    #expect(rejected > accepted)
  }
}
