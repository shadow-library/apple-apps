import Foundation

public struct ObjectKey: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public static let maxUTF8Length = 512

  public let rawValue: String

  public init?(_ rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let key = ObjectKey(value) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid object key: \(value)") }
    self = key
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public var description: String { rawValue }

  public func hasPrefix(_ prefix: String) -> Bool {
    rawValue.utf8.starts(with: prefix.utf8)
  }

  public static func < (lhs: ObjectKey, rhs: ObjectKey) -> Bool {
    lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
  }

  private static func isValid(_ value: String) -> Bool {
    guard (1...maxUTF8Length).contains(value.utf8.count) else { return false }
    return value.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false).allSatisfy(isValidSegment)
  }

  private static func isValidSegment(_ segment: Substring.UTF8View) -> Bool {
    guard !segment.isEmpty, !segment.allSatisfy({ $0 == UInt8(ascii: ".") }) || segment.count > 2 else { return false }
    return segment.allSatisfy(isAllowed)
  }

  private static func isAllowed(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
    case UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"): true
    default: false
    }
  }
}
