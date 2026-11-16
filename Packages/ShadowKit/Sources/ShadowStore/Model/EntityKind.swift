public struct EntityKind: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public let rawValue: String

  public init?(_ rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public static func < (lhs: EntityKind, rhs: EntityKind) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let kind = EntityKind(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Entity kind must be 1 to 64 characters of [a-z0-9_]") }
    self = kind
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func isValid(_ text: String) -> Bool {
    let bytes = text.utf8
    guard (1...64).contains(bytes.count) else { return false }
    return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "_") }
  }
}
