import Foundation

public struct VaultFileSealer: Sendable {
  public let header: Data
  var cipher: ChunkCipher

  public init(path: String, vault: VaultID, key: VaultKey, chunkSize: Int = VaultFile.defaultChunkSize) throws(VaultFileError) {
    try self.init(path: path, vault: vault, key: key, chunkSize: chunkSize, randomness: .system())
  }

  init(path: String, vault: VaultID, key: VaultKey, chunkSize: Int, randomness: SealRandomness) throws(VaultFileError) {
    guard (1...VaultFile.maximumChunkSize).contains(chunkSize) else { throw .invalidChunkSize(chunkSize) }
    let pathBytes = try VaultFile.pathBytes(path)
    let fileHeader = VaultFileHeader(
      formatVersion: VaultFormat.version,
      vault: vault,
      keyID: key.id,
      chunkSize: chunkSize,
      fileSalt: randomness.fileSalt,
      noncePrefix: randomness.noncePrefix
    )
    header = fileHeader.encoded
    cipher = ChunkCipher(header: fileHeader, encodedHeader: header, ringKey: key, pathBytes: pathBytes)
  }

  public var chunkSize: Int { cipher.chunkSize }

  public var isFinished: Bool { cipher.isFinished }

  public mutating func seal(chunk: Data, isFinal: Bool) throws(VaultFileError) -> Data {
    try cipher.seal(chunk, isFinal: isFinal)
  }
}
