import CryptoKit
import Foundation

enum ChunkState: Sendable {
  case active(next: UInt64)
  case finished
  case failed(VaultFileError)
}

struct ChunkCipher: Sendable {
  let chunkSize: Int
  var state = ChunkState.active(next: 0)
  private let key: SymmetricKey
  private let associatedData: Data
  private let noncePrefix: [UInt8]

  init(header: VaultFileHeader, encodedHeader: Data, ringKey: VaultKey, pathBytes: [UInt8]) {
    chunkSize = header.chunkSize
    noncePrefix = header.noncePrefix
    key = VaultFile.fileKey(ringKey: ringKey, vault: header.vault, fileSalt: header.fileSalt, pathBytes: pathBytes)
    associatedData = VaultFile.associatedData(encodedHeader: encodedHeader, pathBytes: pathBytes)
  }

  var isFinished: Bool {
    if case .finished = state { return true }
    return false
  }

  mutating func seal(_ plaintext: Data, isFinal: Bool) throws(VaultFileError) -> Data {
    let index = try begin(plaintextLength: plaintext.count, isFinal: isFinal, whenFinished: .alreadyFinalized)
    let sealed: Data
    do {
      let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(index: index, isFinal: isFinal), authenticating: associatedData)
      sealed = box.ciphertext + box.tag
    } catch {
      try fail(.cryptoFailure)
    }
    advance(from: index, isFinal: isFinal)
    return sealed
  }

  mutating func open(_ chunk: Data, isFinal: Bool) throws(VaultFileError) -> Data {
    let index = try begin(plaintextLength: chunk.count - VaultFile.tagSize, isFinal: isFinal, whenFinished: .trailingData)
    let plaintext: Data
    do {
      let box = try ChaChaPoly.SealedBox(nonce: nonce(index: index, isFinal: isFinal), ciphertext: chunk.dropLast(VaultFile.tagSize), tag: chunk.suffix(VaultFile.tagSize))
      plaintext = try ChaChaPoly.open(box, using: key, authenticating: associatedData)
    } catch {
      try fail(.authenticationFailed)
    }
    advance(from: index, isFinal: isFinal)
    return plaintext
  }

  private mutating func begin(plaintextLength: Int, isFinal: Bool, whenFinished: VaultFileError) throws(VaultFileError) -> UInt64 {
    switch state {
    case .failed(let error): throw error
    case .finished: try fail(whenFinished)
    case .active(let index):
      guard index < VaultFile.maximumChunkCount else { try fail(.tooManyChunks) }
      guard isValid(plaintextLength: plaintextLength, index: index, isFinal: isFinal) else { try fail(.invalidChunkLength) }
      return index
    }
  }

  private func isValid(plaintextLength: Int, index: UInt64, isFinal: Bool) -> Bool {
    guard isFinal else { return plaintextLength == chunkSize }
    guard plaintextLength > 0 else { return plaintextLength == 0 && index == 0 }
    return plaintextLength <= chunkSize
  }

  private mutating func advance(from index: UInt64, isFinal: Bool) {
    state = isFinal ? .finished : .active(next: index + 1)
  }

  private mutating func fail(_ error: VaultFileError) throws(VaultFileError) -> Never {
    state = .failed(error)
    throw error
  }

  private func nonce(index: UInt64, isFinal: Bool) throws -> ChaChaPoly.Nonce {
    var bytes = Data(noncePrefix)
    bytes.append(bigEndian: UInt32(index))
    bytes.append(isFinal ? 0x01 : 0x00)
    return try ChaChaPoly.Nonce(data: bytes)
  }
}
