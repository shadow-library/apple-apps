import CryptoKit
import Foundation

/// A digest of the account a location was attached with, so the raw account identifier is never written to disk.
public struct SyncAccountBinding: Sendable, Hashable, Codable, CustomStringConvertible {
  static let domain = "com.shadow.library.shadowsyncruntime.account-binding"
  private static let digestLength = 64

  public let digest: String

  public init(kind: SyncProviderKind, account: String) {
    var hasher = SHA256()
    for part in [Self.domain, kind.rawValue, account] {
      hasher.update(data: Data(part.utf8))
      hasher.update(data: Data([0]))
    }
    digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public init?(digest: String) {
    guard digest.utf8.count == Self.digestLength, digest.utf8.allSatisfy(Self.isLowerHex) else { return nil }
    self.digest = digest
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let binding = SyncAccountBinding(digest: try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "An account binding is 64 lower-case hex characters")
    }
    self = binding
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(digest)
  }

  public var description: String { "SyncAccountBinding(\(digest.prefix(8)))" }

  private static func isLowerHex(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"): true
    default: false
    }
  }
}
