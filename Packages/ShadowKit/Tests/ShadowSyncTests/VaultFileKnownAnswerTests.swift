import CryptoKit
import Foundation
import Testing

@testable import ShadowSync

@Suite("VaultFile known-answer vector")
struct VaultFileKnownAnswerTests {
  private static let keyBytes = Data(0..<32)
  private static let keyIDBytes: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
  private static let vault = "kat-vault"
  private static let path = "bases/ünïcode.json"
  private static let fileSalt: [UInt8] = [0x5A, 0x4C, 0x54, 0x31, 0x00, 0x01, 0x02, 0x03, 0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87]
  private static let noncePrefix: [UInt8] = [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6]
  private static let plaintext = Data("hello, vault".utf8)
  private static let expectedHex = [
    "534c5631010000096b61742d7661756c74",
    "00112233445566778899aabbccddeeff",
    "5a4c543100010203f0e1d2c3b4a59687",
    "a0a1a2a3a4a5a6",
    "00000004",
    "9c1a5c6c5b24fcc335aecc420d652bcbcec939b5",
    "eb19adfcc71c41442d16ad82861752bd4f9220aa",
    "b282075db80b87f4a61c68497a4a40e3c6a54225",
  ].joined()

  private static func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
  }

  private static func rebuildFromPrimitives() throws -> Data {
    let vaultBytes = Data(vault.utf8)
    let pathBytes = Data(path.utf8)
    var header = Data([0x53, 0x4C, 0x56, 0x31, 0x01, 0x00, 0x00, UInt8(vaultBytes.count)])
    header += vaultBytes
    header += keyIDBytes
    header += fileSalt
    header += noncePrefix
    header += [0x00, 0x00, 0x00, 0x04]

    let fileKey = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: keyBytes),
      salt: vaultBytes,
      info: Data("SLV1/file".utf8) + [0x00] + fileSalt + pathBytes,
      outputByteCount: 32
    )
    let associatedData = Data(SHA256.hash(data: header + [0x00, 0x00, 0x00, UInt8(pathBytes.count)] + pathBytes))

    var output = header
    for index in 0..<3 {
      let nonce = try ChaChaPoly.Nonce(data: noncePrefix + [0x00, 0x00, 0x00, UInt8(index), index == 2 ? 0x01 : 0x00])
      let chunk = plaintext[(index * 4)..<(index * 4 + 4)]
      let box = try ChaChaPoly.seal(chunk, using: fileKey, nonce: nonce, authenticating: associatedData)
      output += box.ciphertext + box.tag
    }
    return output
  }

  @Test("should match the vector rebuilt from CryptoKit primitives and the pinned bytes")
  func shouldMatchKnownAnswer() throws {
    let keyID = KeyID(try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")))
    let key = try #require(VaultKey(id: keyID, rawBytes: Self.keyBytes))
    let vault = try #require(VaultID(Self.vault))
    let randomness = SealRandomness(fileSalt: Self.fileSalt, noncePrefix: Self.noncePrefix)
    let sealed = try VaultFile.seal(Self.plaintext, path: Self.path, vault: vault, key: key, chunkSize: 4, randomness: randomness)
    #expect(sealed == (try Self.rebuildFromPrimitives()))
    #expect(Self.hex(sealed) == Self.expectedHex)
    #expect(try VaultFile.open(sealed, path: Self.path, vault: vault) { $0 == keyID ? key : nil } == Self.plaintext)
  }
}
