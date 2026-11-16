import Foundation

public struct ReplicaID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
  public let uuid: UUID

  public init(_ uuid: UUID) {
    self.uuid = uuid
  }

  public init?(_ description: String) {
    let bytes = Array(description.utf8)
    guard bytes.count == 36 else { return nil }
    for (index, byte) in bytes.enumerated() {
      if [8, 13, 18, 23].contains(index) {
        guard byte == 0x2D else { return nil }
        continue
      }
      guard (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte) else { return nil }
    }
    guard let uuid = UUID(uuidString: description) else { return nil }
    self.uuid = uuid
  }

  public var description: String {
    uuid.uuidString.lowercased()
  }

  public static func < (lhs: ReplicaID, rhs: ReplicaID) -> Bool {
    lhs.description.utf8.lexicographicallyPrecedes(rhs.description.utf8)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let replica = ReplicaID(text) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Replica id must be a canonical lower-case UUID")
    }
    self = replica
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}
