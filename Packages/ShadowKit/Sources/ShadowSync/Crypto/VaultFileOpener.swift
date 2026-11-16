import Foundation

public struct VaultFileOpener: Sendable {
  public let header: VaultFileHeader
  var cipher: ChunkCipher

  public init(header encodedHeader: Data, path: String, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(VaultFileError) {
    let parsed = try VaultFileHeader.parse(encodedHeader)
    guard parsed.encodedLength == encodedHeader.count else { throw .trailingData }
    guard parsed.vault == vault else { throw .vaultMismatch(expected: vault, found: parsed.vault) }
    guard let key = keys(parsed.keyID), key.id == parsed.keyID else { throw .keyUnavailable(parsed.keyID) }
    let pathBytes = try VaultFile.pathBytes(path)
    header = parsed
    cipher = ChunkCipher(header: parsed, encodedHeader: Data(encodedHeader), ringKey: key, pathBytes: pathBytes)
  }

  public var sealedChunkSize: Int { header.chunkSize + VaultFile.tagSize }

  public var isFinished: Bool { cipher.isFinished }

  /// Returned plaintext is only trustworthy as a whole once `finish()` succeeds; a stream can be cut at any chunk boundary.
  public mutating func open(chunk: Data, isFinal: Bool) throws(VaultFileError) -> Data {
    try cipher.open(chunk, isFinal: isFinal)
  }

  public func finish() throws(VaultFileError) {
    if case .failed(let error) = cipher.state { throw error }
    guard isFinished else { throw .truncated }
  }
}
