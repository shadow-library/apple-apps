import CryptoKit
import Foundation

public struct ContentTag: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
  static let byteCount = 16
  static let length = 2 * byteCount
  static let keyInfo = Data("SLV1/content-tag".utf8)

  public let description: String

  public init?(_ description: String) {
    guard CodecText.isLowerHex(description, count: Self.length) else { return nil }
    self.description = description
  }

  private init(validated description: String) {
    self.description = description
  }

  public static func make(for payload: Data, key: VaultKey) -> ContentTag {
    var mac = HMAC<SHA256>(key: tagKey(key))
    mac.update(data: payload)
    return ContentTag(mac: mac)
  }

  static func make(lines: some Sequence<Data>, key: VaultKey) -> ContentTag {
    var mac = HMAC<SHA256>(key: tagKey(key))
    let newline = Data([CodecFrame.newline])
    for line in lines {
      mac.update(data: line)
      mac.update(data: newline)
    }
    return ContentTag(mac: mac)
  }

  public static func < (lhs: ContentTag, rhs: ContentTag) -> Bool {
    lhs.description.utf8.lexicographicallyPrecedes(rhs.description.utf8)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let tag = ContentTag(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid content tag") }
    self = tag
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  private init(mac: HMAC<SHA256>) {
    self.init(validated: lowercaseHex(mac.finalize().prefix(Self.byteCount)))
  }

  private static func tagKey(_ key: VaultKey) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: key.symmetricKey, salt: Data(), info: keyInfo, outputByteCount: 32)
  }
}

public struct StreamPoint: Hashable, Comparable, Sendable, Codable {
  public let last: Int64
  public let tag: ContentTag

  public init(last: Int64, tag: ContentTag) {
    self.last = last
    self.tag = tag
  }

  public static func < (lhs: StreamPoint, rhs: StreamPoint) -> Bool {
    (lhs.last, lhs.tag) < (rhs.last, rhs.tag)
  }

  var isOnStream: Bool { last >= 1 && last <= VaultPath.maximumSequence }
}
