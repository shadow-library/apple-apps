import CryptoKit
import Foundation
import ShadowCore

public struct EntityKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  private static let hexDigits = Array("0123456789abcdef".utf8)

  public let rawValue: String

  public init?(_ rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public init(uuid: UUID) {
    rawValue = uuid.uuidString.lowercased()
  }

  private init(validated rawValue: String) {
    self.rawValue = rawValue
  }

  public static func natural(scope: String, kind: EntityKind, components: [String]) -> EntityKey {
    let preimage = CanonicalJSON.encode(.array(([scope, kind.rawValue] + components).map(JSONValue.string)))
    let digest = SHA256.hash(data: preimage)
    var text = Array("n:".utf8)
    for byte in digest.prefix(20) { text.append(contentsOf: [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]) }
    return EntityKey(validated: String(decoding: text, as: UTF8.self))
  }

  public var description: String { rawValue }

  public static func < (lhs: EntityKey, rhs: EntityKey) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let key = EntityKey(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Entity key must be 1 to 128 characters of [a-z0-9:_-]") }
    self = key
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func isValid(_ text: String) -> Bool {
    let bytes = text.utf8
    guard (1...128).contains(bytes.count) else { return false }
    return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || [UInt8(ascii: ":"), UInt8(ascii: "_"), UInt8(ascii: "-")].contains($0) }
  }
}
