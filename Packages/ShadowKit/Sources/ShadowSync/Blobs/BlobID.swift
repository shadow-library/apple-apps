import Foundation

/// Random, so it names an object without saying anything about its content, and can be minted with no vault key; a record stores `description`.
public struct BlobID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, LosslessStringConvertible {
  static let byteCount = 32
  static let length = 2 * byteCount

  public let description: String

  public init?(_ description: String) {
    guard CodecText.isLowerHex(description, count: Self.length) else { return nil }
    self.description = description
  }

  private init(validated description: String) {
    self.description = description
  }

  public static func random() -> BlobID {
    var generator = SystemRandomNumberGenerator()
    return BlobID(validated: lowercaseHex((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
  }

  public static func < (lhs: BlobID, rhs: BlobID) -> Bool {
    lhs.description.utf8.lexicographicallyPrecedes(rhs.description.utf8)
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    guard let id = BlobID(text) else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid blob id") }
    self = id
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  var prefix: String { VaultPath.blobPrefix(description) }

  func partKeys(_ parts: Int) -> [ObjectKey] {
    (1...parts).map { VaultPath.blobPart(name: description, part: $0, parts: parts) }
  }

}

/// Finds which of a set of ids a stored byte string names, written as a run of 64 lower-case hex digits or inside a longer run; a false match only keeps a
/// blob longer.
struct BlobIDMatcher {
  let candidates: Set<BlobID>
  private let prefixes: Set<UInt64>

  init(_ candidates: some Sequence<BlobID>) {
    self.candidates = Set(candidates)
    prefixes = Set(self.candidates.map { Self.prefix(Array($0.description.utf8)[...]) })
  }

  /// Adds the candidates `bytes` names to `found` and answers whether any candidate is still unfound.
  func scan(_ bytes: Data, into found: inout Set<BlobID>) -> Bool {
    guard found.count < candidates.count else { return false }
    bytes.withUnsafeBytes { raw in
      var runStart = 0
      for index in 0...raw.count {
        if index < raw.count, CodecText.isLowerHexDigit(raw[index]) { continue }
        if index - runStart >= BlobID.length {
          for start in runStart...(index - BlobID.length) {
            let window = raw[start..<(start + BlobID.length)]
            guard prefixes.contains(Self.prefix(window)), let id = BlobID(String(decoding: UnsafeRawBufferPointer(rebasing: window), as: UTF8.self)) else { continue }
            if candidates.contains(id) { found.insert(id) }
          }
        }
        runStart = index + 1
      }
    }
    return found.count < candidates.count
  }

  private static func prefix(_ bytes: some Collection<UInt8>) -> UInt64 {
    bytes.prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
  }
}
