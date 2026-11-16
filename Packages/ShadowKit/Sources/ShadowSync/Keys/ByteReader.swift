import Foundation

struct ByteReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(_ bytes: [UInt8]) {
    self.bytes = bytes
  }

  var remaining: Int { bytes.count - offset }

  mutating func read(_ count: Int) -> [UInt8]? {
    guard count >= 0, count <= remaining else { return nil }
    defer { offset += count }
    return Array(bytes[offset..<(offset + count)])
  }

  mutating func readByte() -> UInt8? {
    read(1)?.first
  }

  mutating func readUInt16() -> UInt16? {
    read(2).map { UInt16($0[0]) << 8 | UInt16($0[1]) }
  }

  mutating func readKeyID() -> KeyID? {
    read(16).map { KeyID(bytes: $0) }
  }

  mutating func readVaultID(length: Int) -> VaultID? {
    guard (1...VaultID.maximumLength).contains(length), let raw = read(length) else { return nil }
    return VaultID(String(decoding: raw, as: UTF8.self))
  }
}
