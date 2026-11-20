import CryptoKit
import Foundation

public struct RecoveryPhrase: Sendable {
  public static let wordCount = 24

  private static let bitsPerWord = 11
  private static let wordMask: UInt32 = 0x7FF
  private static let wordIndexes: [String: Int] = Dictionary(uniqueKeysWithValues: RecoveryWordList.words.enumerated().map { ($1, $0) })

  public let secret: RecoverySecret

  public init(secret: RecoverySecret) {
    self.secret = secret
  }

  public init(parsing text: String) throws(RecoveryPhraseError) {
    let tokens = Self.normalise(text)
    guard tokens.count == Self.wordCount else { throw .wrongWordCount(found: tokens.count) }
    var bytes = Data()
    var buffer: UInt32 = 0
    var bitCount = 0
    for (offset, token) in tokens.enumerated() {
      guard let index = Self.wordIndexes[token] else { throw .unknownWord(position: offset + 1) }
      buffer = (buffer << UInt32(Self.bitsPerWord)) | UInt32(index)
      bitCount += Self.bitsPerWord
      while bitCount >= 8 {
        bitCount -= 8
        bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bitCount)))
      }
      buffer &= (1 << UInt32(bitCount)) - 1
    }
    let entropy = bytes.prefix(RecoverySecret.byteCount)
    guard let secret = RecoverySecret(rawBytes: Data(entropy)) else { preconditionFailure("24 words carry 33 bytes") }
    guard constantTimeEquals(bytes.suffix(1), Self.checksum(of: entropy)) else { throw .badChecksum }
    self.secret = secret
  }

  public var words: [String] {
    let entropy = secret.rawBytes
    var buffer: UInt32 = 0
    var bitCount = 0
    var words: [String] = []
    for byte in entropy + Self.checksum(of: entropy) {
      buffer = (buffer << 8) | UInt32(byte)
      bitCount += 8
      guard bitCount >= Self.bitsPerWord else { continue }
      bitCount -= Self.bitsPerWord
      words.append(RecoveryWordList.words[Int((buffer >> UInt32(bitCount)) & Self.wordMask)])
      buffer &= (1 << UInt32(bitCount)) - 1
    }
    return words
  }

  private static func checksum(of entropy: some DataProtocol) -> Data {
    Data(SHA256.hash(data: entropy).prefix(1))
  }

  private static func normalise(_ text: String) -> [String] {
    text.decomposedStringWithCompatibilityMapping.lowercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
  }
}

extension RecoveryPhrase: Equatable {
  public static func == (lhs: RecoveryPhrase, rhs: RecoveryPhrase) -> Bool {
    constantTimeEquals(lhs.secret.rawBytes, rhs.secret.rawBytes)
  }
}

extension RecoveryPhrase: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "RecoveryPhrase(redacted)" }
  public var debugDescription: String { description }
}

extension RecoveryPhrase: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: [], displayStyle: .struct)
  }
}
