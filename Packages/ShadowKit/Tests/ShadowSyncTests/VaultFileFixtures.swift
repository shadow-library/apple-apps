import Foundation
import Testing

@testable import ShadowSync

enum VaultFileFixtures {
  static let path = "bases/library.json"
  static let vaultCharacters = Array("abcdefghijklmnopqrstuvwxyz0123456789-")

  static func vault(_ rawValue: String = "vault-one") throws -> VaultID {
    try #require(VaultID(rawValue))
  }

  static func key(id: KeyID = KeyID(UUID()), byte: UInt8 = 0x42) throws -> VaultKey {
    try #require(VaultKey(id: id, rawBytes: Data(repeating: byte, count: 32)))
  }

  static func ring(_ keys: VaultKey...) -> (KeyID) -> VaultKey? {
    { id in keys.first { $0.id == id } }
  }

  static func plaintext(count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
  }

  static func split(_ sealed: Data, chunkSize: Int) throws -> (header: Data, chunks: [Data]) {
    let headerLength = try VaultFile.header(of: sealed).encodedLength
    let body = Data(sealed.dropFirst(headerLength))
    let sealedChunkSize = chunkSize + VaultFile.tagSize
    let chunks = stride(from: 0, to: body.count, by: sealedChunkSize).map { body[$0..<min($0 + sealedChunkSize, body.count)] }
    return (Data(sealed.prefix(headerLength)), chunks.map { Data($0) })
  }

  static func join(_ header: Data, _ chunks: [Data]) -> Data {
    chunks.reduce(header, +)
  }
}
