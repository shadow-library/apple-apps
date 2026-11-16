import Foundation
import Testing

@testable import ShadowSync

@Suite("VaultFileHeader")
struct VaultFileHeaderTests {
  private static let keyID = KeyID(UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)))

  private static func header(version: UInt8 = 1, flags: UInt8 = 0, vaultLength: UInt16? = nil, vault: [UInt8] = Array("vault".utf8), chunkSize: UInt32 = 8) -> Data {
    let length = vaultLength ?? UInt16(vault.count)
    var data = VaultFormat.magic + Data([version, flags, UInt8(length >> 8), UInt8(length & 0xFF)])
    data.append(contentsOf: vault)
    data.append(contentsOf: keyID.bytes)
    data.append(contentsOf: Array(0xF0...0xFF) as [UInt8])
    data.append(contentsOf: [1, 2, 3, 4, 5, 6, 7])
    data.append(contentsOf: [UInt8(chunkSize >> 24), UInt8((chunkSize >> 16) & 0xFF), UInt8((chunkSize >> 8) & 0xFF), UInt8(chunkSize & 0xFF)])
    return data
  }

  @Test("should parse a well-formed header and ignore the body")
  func shouldParseHeader() throws {
    let parsed = try VaultFile.header(of: Self.header(chunkSize: 300) + Data(repeating: 0xEE, count: 40))
    #expect(parsed.formatVersion == 1)
    #expect(parsed.vault == VaultID("vault"))
    #expect(parsed.keyID == Self.keyID)
    #expect(parsed.chunkSize == 300)
    #expect(parsed.fileSalt == Array(0xF0...0xFF))
    #expect(parsed.noncePrefix == [1, 2, 3, 4, 5, 6, 7])
    #expect(parsed.encodedLength == 56)
    #expect(parsed.encoded == Self.header(chunkSize: 300))
  }

  @Test("should accept the extreme vault id lengths and chunk sizes")
  func shouldAcceptBounds() throws {
    let longest = Array(String(repeating: "a", count: 64).utf8)
    #expect(try VaultFile.header(of: Self.header(vault: longest)).vault.rawValue.count == 64)
    #expect(try VaultFile.header(of: Self.header(vault: [UInt8(ascii: "z")])).vault.rawValue == "z")
    #expect(try VaultFile.header(of: Self.header(chunkSize: 1)).chunkSize == 1)
    #expect(try VaultFile.header(of: Self.header(chunkSize: 16_777_216)).chunkSize == 16_777_216)
  }

  @Test("should reject bad magic")
  func shouldRejectBadMagic() {
    var data = Self.header()
    data[0] = UInt8(ascii: "X")
    #expect(throws: VaultFileError.invalidMagic) { try VaultFile.header(of: data) }
    #expect(throws: VaultFileError.invalidMagic) { try VaultFile.header(of: Data("SX".utf8)) }
    #expect(throws: VaultFileError.invalidMagic) { try VaultFile.header(of: Data("{\"json\": true}".utf8)) }
  }

  @Test("should reject an unknown version")
  func shouldRejectUnknownVersion() {
    for version: UInt8 in [0, 2, 0xFF] {
      #expect(throws: VaultFileError.unsupportedVersion(version)) { try VaultFile.header(of: Self.header(version: version)) }
    }
  }

  @Test("should reject non-zero flags")
  func shouldRejectFlags() {
    for flags: UInt8 in [1, 0x80, 0xFF] {
      #expect(throws: VaultFileError.unsupportedFlags(flags)) { try VaultFile.header(of: Self.header(flags: flags)) }
    }
  }

  @Test("should reject an out-of-range vault id length")
  func shouldRejectVaultLength() {
    #expect(throws: VaultFileError.invalidVaultID) { try VaultFile.header(of: Self.header(vault: [])) }
    #expect(throws: VaultFileError.invalidVaultID) { try VaultFile.header(of: Self.header(vault: Array(String(repeating: "a", count: 65).utf8))) }
    #expect(throws: VaultFileError.invalidVaultID) { try VaultFile.header(of: Self.header(vaultLength: 0xFFFF)) }
  }

  @Test("should reject vault id bytes outside the allowed alphabet")
  func shouldRejectVaultCharacters() {
    for vault in [Array("Vault".utf8), Array("va ult".utf8), Array("vault/".utf8), [0x76, 0xFF, 0x61], Array("vaült".utf8)] {
      #expect(throws: VaultFileError.invalidVaultID) { try VaultFile.header(of: Self.header(vault: vault)) }
    }
  }

  @Test("should reject an out-of-range chunk size")
  func shouldRejectChunkSize() {
    for size: UInt32 in [0, 16_777_217, UInt32.max] {
      #expect(throws: VaultFileError.invalidChunkSize(Int(size))) { try VaultFile.header(of: Self.header(chunkSize: size)) }
    }
  }

  @Test("should reject a header cut inside the file salt")
  func shouldRejectTruncatedSalt() {
    let data = Self.header()
    let saltStart = 24 + 5
    for length in saltStart..<(saltStart + VaultFile.fileSaltSize) {
      #expect(throws: VaultFileError.truncatedHeader, "length \(length)") { try VaultFile.header(of: data.prefix(length)) }
    }
  }

  @Test("should reject every truncated header")
  func shouldRejectTruncatedHeader() {
    let data = Self.header()
    for length in 0..<data.count {
      #expect(throws: VaultFileError.truncatedHeader, "length \(length)") { try VaultFile.header(of: data.prefix(length)) }
    }
  }
}
