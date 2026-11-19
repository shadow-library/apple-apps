import CryptoKit
import Foundation

/// A version 8 UUID named by `name` under `domain`, the same on every device and attempt.
func derivedID(_ domain: String, _ name: String) -> UUID {
  var bytes = Array(SHA256.hash(data: Data("\(domain):\(name)".utf8)).prefix(16))
  bytes[6] = (bytes[6] & 0x0F) | 0x80
  bytes[8] = (bytes[8] & 0x3F) | 0x80
  return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
}
