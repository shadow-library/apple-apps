import CryptoKit
import Foundation

public enum VaultFile {
  public static let defaultChunkSize = 1 << 20
  public static let maximumChunkSize = 1 << 24
  public static let tagSize = 16
  static let fileSaltSize = 16
  static let noncePrefixSize = 7
  static let fixedHeaderLength = 51
  static let maximumHeaderLength = fixedHeaderLength + VaultID.maximumLength
  static let maximumChunkCount = UInt64(UInt32.max) + 1
  static let fileKeyInfo = Data("SLV1/file".utf8)

  public static func seal(_ plaintext: Data, path: String, vault: VaultID, key: VaultKey, chunkSize: Int = defaultChunkSize) throws(VaultFileError) -> Data {
    try seal(plaintext, path: path, vault: vault, key: key, chunkSize: chunkSize, randomness: .system())
  }

  static func seal(_ plaintext: Data, path: String, vault: VaultID, key: VaultKey, chunkSize: Int, randomness: SealRandomness) throws(VaultFileError) -> Data {
    var sealer = try VaultFileSealer(path: path, vault: vault, key: key, chunkSize: chunkSize, randomness: randomness)
    let chunkCount = max(1, (plaintext.count + chunkSize - 1) / chunkSize)
    var output = sealer.header
    output.reserveCapacity(output.count + plaintext.count + chunkCount * tagSize)
    var start = plaintext.startIndex
    repeat {
      let end = plaintext.index(start, offsetBy: chunkSize, limitedBy: plaintext.endIndex) ?? plaintext.endIndex
      output.append(try sealer.seal(chunk: plaintext[start..<end], isFinal: end == plaintext.endIndex))
      start = end
    } while start < plaintext.endIndex
    return output
  }

  public static func open(_ sealed: Data, path: String, vault: VaultID, keys: (KeyID) -> VaultKey?) throws(VaultFileError) -> Data {
    let header = try VaultFileHeader.parse(sealed)
    let headerEnd = sealed.startIndex + header.encodedLength
    var opener = try VaultFileOpener(header: sealed[sealed.startIndex..<headerEnd], path: path, vault: vault, keys: keys)
    let sealedChunkSize = header.chunkSize + tagSize
    var plaintext = Data(capacity: max(0, sealed.endIndex - headerEnd))
    var start = headerEnd
    while sealed.endIndex - start > sealedChunkSize {
      plaintext.append(try opener.open(chunk: sealed[start..<(start + sealedChunkSize)], isFinal: false))
      start += sealedChunkSize
    }
    guard sealed.endIndex - start >= tagSize else { throw .truncated }
    plaintext.append(try opener.open(chunk: sealed[start...], isFinal: true))
    return plaintext
  }

  /// Parses the plaintext header only; it is unauthenticated until a chunk verifies.
  public static func header(of sealed: Data) throws(VaultFileError) -> VaultFileHeader {
    try VaultFileHeader.parse(sealed)
  }

  static func pathBytes(_ path: String) throws(VaultFileError) -> [UInt8] {
    let bytes = Array(path.utf8)
    guard bytes.count <= UInt32.max else { throw .pathTooLong }
    return bytes
  }

  static func fileKey(ringKey: VaultKey, vault: VaultID, fileSalt: [UInt8], pathBytes: [UInt8]) -> SymmetricKey {
    var info = fileKeyInfo
    info.append(0)
    info.append(contentsOf: fileSalt)
    info.append(contentsOf: pathBytes)
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: ringKey.symmetricKey, salt: Data(vault.rawValue.utf8), info: info, outputByteCount: 32)
  }

  static func associatedData(encodedHeader: Data, pathBytes: [UInt8]) -> Data {
    var hasher = SHA256()
    hasher.update(data: encodedHeader)
    var length = Data()
    length.append(bigEndian: UInt32(pathBytes.count))
    hasher.update(data: length)
    hasher.update(data: pathBytes)
    return Data(hasher.finalize())
  }
}

struct SealRandomness: Sendable {
  let fileSalt: [UInt8]
  let noncePrefix: [UInt8]

  init(fileSalt: [UInt8], noncePrefix: [UInt8]) {
    precondition(fileSalt.count == VaultFile.fileSaltSize, "the file salt is \(VaultFile.fileSaltSize) bytes")
    precondition(noncePrefix.count == VaultFile.noncePrefixSize, "the nonce prefix is \(VaultFile.noncePrefixSize) bytes")
    self.fileSalt = fileSalt
    self.noncePrefix = noncePrefix
  }

  static func system() -> SealRandomness {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<(VaultFile.fileSaltSize + VaultFile.noncePrefixSize)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return SealRandomness(fileSalt: Array(bytes.prefix(VaultFile.fileSaltSize)), noncePrefix: Array(bytes.suffix(VaultFile.noncePrefixSize)))
  }
}
