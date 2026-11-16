import Foundation

public struct VaultID: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let maximumLength = 64

  public let rawValue: String

  public init?(_ rawValue: String) {
    let bytes = Array(rawValue.utf8)
    guard (1...Self.maximumLength).contains(bytes.count), bytes.allSatisfy(Self.isAllowed) else { return nil }
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    guard let vault = VaultID(rawValue) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid vault id") }
    self = vault
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private static func isAllowed(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"): true
    default: false
    }
  }
}

public struct KeyID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  public let uuid: UUID

  public init(_ uuid: UUID) {
    self.uuid = uuid
  }

  public init?(_ description: String) {
    guard let uuid = UUID(uuidString: description), uuid.uuidString.lowercased() == description else { return nil }
    self.uuid = uuid
  }

  public var description: String { uuid.uuidString.lowercased() }

  public static func < (lhs: KeyID, rhs: KeyID) -> Bool {
    lhs.description < rhs.description
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let keyID = KeyID(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid key id") }
    self = keyID
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  var bytes: [UInt8] {
    withUnsafeBytes(of: uuid.uuid) { Array($0) }
  }

  init(bytes: some Collection<UInt8>) {
    precondition(bytes.count == 16, "a key id is 16 bytes")
    let raw = Array(bytes)
    uuid = UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7], raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
  }
}
