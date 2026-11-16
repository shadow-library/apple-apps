import Foundation

public struct VaultFileHeader: Sendable, Equatable {
  public let formatVersion: UInt8
  public let vault: VaultID
  public let keyID: KeyID
  public let chunkSize: Int
  let fileSalt: [UInt8]
  let noncePrefix: [UInt8]

  public var encodedLength: Int { VaultFile.fixedHeaderLength + vault.rawValue.utf8.count }

  var encoded: Data {
    let vaultBytes = Array(vault.rawValue.utf8)
    var data = Data(capacity: encodedLength)
    data.append(VaultFormat.magic)
    data.append(formatVersion)
    data.append(0)
    data.append(bigEndian: UInt16(vaultBytes.count))
    data.append(contentsOf: vaultBytes)
    data.append(contentsOf: keyID.bytes)
    data.append(contentsOf: fileSalt)
    data.append(contentsOf: noncePrefix)
    data.append(bigEndian: UInt32(chunkSize))
    return data
  }

  static func parse(_ data: Data) throws(VaultFileError) -> VaultFileHeader {
    let bytes = [UInt8](data.prefix(VaultFile.maximumHeaderLength))
    let magic = [UInt8](VaultFormat.magic)
    guard bytes.starts(with: magic.prefix(bytes.count)) else { throw .invalidMagic }
    guard bytes.count >= 8 else { throw .truncatedHeader }
    guard bytes[4] == VaultFormat.version else { throw .unsupportedVersion(bytes[4]) }
    guard bytes[5] == 0 else { throw .unsupportedFlags(bytes[5]) }
    let vaultLength = Int(bytes.bigEndianInteger(at: 6, as: UInt16.self))
    guard (1...VaultID.maximumLength).contains(vaultLength) else { throw .invalidVaultID }
    guard bytes.count >= VaultFile.fixedHeaderLength + vaultLength else { throw .truncatedHeader }
    guard let vault = VaultID(String(decoding: bytes[8..<(8 + vaultLength)], as: UTF8.self)) else { throw .invalidVaultID }
    let keyStart = 8 + vaultLength
    let saltStart = keyStart + 16
    let nonceStart = saltStart + VaultFile.fileSaltSize
    let chunkSizeStart = nonceStart + VaultFile.noncePrefixSize
    let chunkSize = Int(bytes.bigEndianInteger(at: chunkSizeStart, as: UInt32.self))
    guard (1...VaultFile.maximumChunkSize).contains(chunkSize) else { throw .invalidChunkSize(chunkSize) }
    return VaultFileHeader(
      formatVersion: bytes[4],
      vault: vault,
      keyID: KeyID(bytes: bytes[keyStart..<saltStart]),
      chunkSize: chunkSize,
      fileSalt: Array(bytes[saltStart..<nonceStart]),
      noncePrefix: Array(bytes[nonceStart..<chunkSizeStart])
    )
  }
}

extension Data {
  mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
    Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
  }
}

extension [UInt8] {
  func bigEndianInteger<T: FixedWidthInteger>(at offset: Int, as _: T.Type) -> T {
    self[offset..<(offset + MemoryLayout<T>.size)].reduce(T.zero) { ($0 << 8) | T($1) }
  }
}
