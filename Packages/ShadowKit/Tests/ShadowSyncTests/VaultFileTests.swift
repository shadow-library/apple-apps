import Foundation
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("VaultFile")
struct VaultFileTests {
  private static let chunkSize = 16

  @Test("should round-trip plaintexts around chunk boundaries", arguments: [0, 1, chunkSize - 1, chunkSize, chunkSize + 1, 3 * chunkSize, 3 * chunkSize + 7])
  func shouldRoundTripAroundChunkBoundaries(count: Int) throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: count)
    let sealed = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: Self.chunkSize)
    let chunkCount = max(1, (count + Self.chunkSize - 1) / Self.chunkSize)
    #expect(sealed.count == VaultFile.fixedHeaderLength + vault.rawValue.utf8.count + count + chunkCount * VaultFile.tagSize)
    #expect(try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
  }

  @Test("should round-trip several MiB at the default chunk size")
  func shouldRoundTripDefaultChunkSize() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: 3 * VaultFile.defaultChunkSize + 5)
    let sealed = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key)
    #expect(try VaultFile.header(of: sealed).chunkSize == VaultFile.defaultChunkSize)
    #expect(try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
  }

  @Test("should open a sealed file passed as a slice with a non-zero start index")
  func shouldOpenSlicedInput() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: 40)
    let sealed = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: Self.chunkSize)
    let slice = (Data([1, 2, 3]) + sealed + Data([4])).dropFirst(3).dropLast()
    #expect(slice.startIndex == 3)
    #expect(try VaultFile.open(slice, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
  }

  @Test("should draw a fresh nonce for every seal")
  func shouldDrawFreshNonce() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: 50)
    let first = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: Self.chunkSize)
    let second = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: Self.chunkSize)
    #expect(first != second)
    #expect(try VaultFile.header(of: first).noncePrefix != VaultFile.header(of: second).noncePrefix)
    #expect(try VaultFile.header(of: first).fileSalt != VaultFile.header(of: second).fileSalt)
    #expect(try VaultFile.open(first, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
    #expect(try VaultFile.open(second, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
  }

  @Test("should derive a different file key per seal even when the nonce prefix repeats")
  func shouldDeriveFreshFileKeyPerSeal() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: 20)
    let prefix: [UInt8] = [1, 1, 1, 1, 1, 1, 1]
    let first = SealRandomness(fileSalt: Array(repeating: 0xAA, count: 16), noncePrefix: prefix)
    let second = SealRandomness(fileSalt: Array(repeating: 0xBB, count: 16), noncePrefix: prefix)
    let sealedFirst = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8, randomness: first)
    let sealedSecond = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8, randomness: second)
    let repeated = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8, randomness: first)
    #expect(repeated == sealedFirst)
    let firstChunks = try VaultFileFixtures.split(sealedFirst, chunkSize: 8).chunks
    let secondChunks = try VaultFileFixtures.split(sealedSecond, chunkSize: 8).chunks
    for (lhs, rhs) in zip(firstChunks, secondChunks) {
      #expect(lhs.prefix(lhs.count - VaultFile.tagSize) != rhs.prefix(rhs.count - VaultFile.tagSize))
    }
    #expect(try VaultFile.open(sealedFirst, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
    #expect(try VaultFile.open(sealedSecond, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
  }

  @Test("should fail authentication when any bit of the file salt flips")
  func shouldAuthenticateFileSalt() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let saltStart = 24 + vault.rawValue.utf8.count
    for offset in saltStart..<(saltStart + VaultFile.fileSaltSize) {
      for bit in 0..<8 {
        var tampered = sealed
        tampered[offset] ^= 1 << bit
        #expect(throws: VaultFileError.authenticationFailed, "offset \(offset) bit \(bit)") {
          try VaultFile.open(tampered, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
        }
      }
    }
  }

  @Test("should reject a flip of any single bit")
  func shouldRejectAnyBitFlip() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    for offset in 0..<sealed.count {
      for bit in 0..<8 {
        var tampered = sealed
        tampered[offset] ^= 1 << bit
        #expect(throws: VaultFileError.self, "offset \(offset) bit \(bit)") {
          try VaultFile.open(tampered, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
        }
      }
    }
  }

  @Test("should reject truncation at every length")
  func shouldRejectEveryTruncation() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    for length in 0..<sealed.count {
      #expect(throws: VaultFileError.self, "length \(length)") {
        try VaultFile.open(sealed.prefix(length), path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
      }
    }
  }

  @Test("should reject swapped, duplicated or dropped chunks")
  func shouldRejectReorderedChunks() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 4 * 8 + 3), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let (header, chunks) = try VaultFileFixtures.split(sealed, chunkSize: 8)
    #expect(chunks.count == 5)
    var variants: [[Data]] = []
    variants.append([chunks[1], chunks[0]] + chunks[2...])
    variants.append(Array(chunks[0..<3]) + [chunks[4], chunks[3]])
    variants.append([chunks[0], chunks[0]] + chunks[1...])
    variants.append(chunks + [chunks[4]])
    variants.append([chunks[0]] + chunks[2...])
    variants.append(Array(chunks.dropLast()))
    variants.append(Array(chunks.dropFirst()))
    variants.append([chunks[4]])
    for (index, variant) in variants.enumerated() {
      #expect(throws: VaultFileError.self, "variant \(index)") {
        try VaultFile.open(VaultFileFixtures.join(header, variant), path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
      }
    }
  }

  @Test("should reject a chunk spliced in from another seal of the same path")
  func shouldRejectSplicedChunk() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let plaintext = VaultFileFixtures.plaintext(count: 24)
    let first = try VaultFileFixtures.split(VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8), chunkSize: 8)
    let second = try VaultFileFixtures.split(VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8), chunkSize: 8)
    let spliced = VaultFileFixtures.join(first.header, [first.chunks[0], second.chunks[1], first.chunks[2]])
    #expect(throws: VaultFileError.authenticationFailed) {
      try VaultFile.open(spliced, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
    }
  }

  @Test("should reject bytes appended after the final chunk")
  func shouldRejectAppendedBytes() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let (_, chunks) = try VaultFileFixtures.split(sealed, chunkSize: 8)
    for suffix in [Data([0]), Data(repeating: 0, count: 16), Data(repeating: 0xFF, count: 24), chunks[0], chunks[2]] {
      #expect(throws: VaultFileError.self) {
        try VaultFile.open(sealed + suffix, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
      }
    }
  }

  @Test("should reject a file opened under a different path")
  func shouldRejectDifferentPath() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: "bases/a.json", vault: vault, key: key, chunkSize: 8)
    for path in ["bases/b.json", "bases/a.json ", "", "Bases/a.json", "bases/a.json\u{0}"] {
      #expect(throws: VaultFileError.authenticationFailed) {
        try VaultFile.open(sealed, path: path, vault: vault, keys: VaultFileFixtures.ring(key))
      }
    }
  }

  @Test("should reject a file from a different vault")
  func shouldRejectDifferentVault() throws {
    let key = try VaultFileFixtures.key()
    let source = try VaultFileFixtures.vault("vault-one")
    let target = try VaultFileFixtures.vault("vault-two")
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: source, key: key, chunkSize: 8)
    #expect(throws: VaultFileError.vaultMismatch(expected: target, found: source)) {
      try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: target, keys: VaultFileFixtures.ring(key))
    }
    var relabelled = sealed
    relabelled.replaceSubrange(8..<17, with: Data("vault-two".utf8))
    #expect(throws: VaultFileError.authenticationFailed) {
      try VaultFile.open(relabelled, path: VaultFileFixtures.path, vault: target, keys: VaultFileFixtures.ring(key))
    }
  }

  @Test("should reject a different key carrying the same key id")
  func shouldRejectImpostorKey() throws {
    let id = KeyID(UUID())
    let key = try VaultFileFixtures.key(id: id, byte: 0x01)
    let impostor = try VaultFileFixtures.key(id: id, byte: 0x02)
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    #expect(throws: VaultFileError.authenticationFailed) {
      try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(impostor))
    }
  }

  @Test("should report the missing key id when the ring lacks it")
  func shouldReportUnavailableKey() throws {
    let key = try VaultFileFixtures.key()
    let other = try VaultFileFixtures.key(byte: 0x07)
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    #expect(throws: VaultFileError.keyUnavailable(key.id)) {
      try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(other))
    }
    #expect(throws: VaultFileError.keyUnavailable(key.id)) {
      try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault) { _ in other }
    }
  }

  @Test("should reject a key id swapped for another key in the ring")
  func shouldRejectSwappedKeyID() throws {
    let key = try VaultFileFixtures.key(byte: 0x01)
    let other = try VaultFileFixtures.key(byte: 0x02)
    let vault = try VaultFileFixtures.vault()
    var sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let keyStart = 8 + vault.rawValue.utf8.count
    sealed.replaceSubrange(keyStart..<(keyStart + 16), with: other.id.bytes)
    #expect(throws: VaultFileError.authenticationFailed) {
      try VaultFile.open(sealed, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key, other))
    }
  }

  @Test("should end a positive multiple of the chunk size with a full final chunk")
  func shouldNotEmitEmptyTrailingChunk() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 16), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let (_, chunks) = try VaultFileFixtures.split(sealed, chunkSize: 8)
    #expect(chunks.map(\.count) == [24, 24])
  }

  @Test("should produce identical bytes incrementally and in one shot")
  func shouldMatchIncrementalAndOneShot() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let randomness = SealRandomness(fileSalt: Array(0..<16), noncePrefix: [9, 8, 7, 6, 5, 4, 3])
    let plaintext = VaultFileFixtures.plaintext(count: 30)
    let oneShot = try VaultFile.seal(plaintext, path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8, randomness: randomness)
    var sealer = try VaultFileSealer(path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8, randomness: randomness)
    var incremental = sealer.header
    for start in stride(from: 0, to: plaintext.count, by: 8) {
      let end = min(start + 8, plaintext.count)
      incremental.append(try sealer.seal(chunk: plaintext[start..<end], isFinal: end == plaintext.count))
    }
    #expect(sealer.isFinished)
    #expect(incremental == oneShot)

    let (header, chunks) = try VaultFileFixtures.split(oneShot, chunkSize: 8)
    var opener = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
    #expect(opener.sealedChunkSize == 24)
    var opened = Data()
    for (index, chunk) in chunks.enumerated() {
      opened.append(try opener.open(chunk: chunk, isFinal: index == chunks.count - 1))
    }
    try opener.finish()
    #expect(opened == plaintext)
  }

  @Test("should reject misuse of the incremental sealer")
  func shouldRejectSealerMisuse() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    for chunkSize in [0, -1, VaultFile.maximumChunkSize + 1] {
      #expect(throws: VaultFileError.invalidChunkSize(chunkSize)) { try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: chunkSize) }
    }
    #expect(try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: VaultFile.maximumChunkSize).chunkSize == VaultFile.maximumChunkSize)

    var short = try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: 8)
    #expect(throws: VaultFileError.invalidChunkLength) { try short.seal(chunk: Data(count: 7), isFinal: false) }
    #expect(throws: VaultFileError.invalidChunkLength) { try short.seal(chunk: Data(count: 8), isFinal: false) }

    var oversized = try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: 8)
    #expect(throws: VaultFileError.invalidChunkLength) { try oversized.seal(chunk: Data(count: 9), isFinal: true) }

    var trailingEmpty = try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: 8)
    _ = try trailingEmpty.seal(chunk: Data(count: 8), isFinal: false)
    #expect(throws: VaultFileError.invalidChunkLength) { try trailingEmpty.seal(chunk: Data(), isFinal: true) }

    var finished = try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: 8)
    _ = try finished.seal(chunk: Data(count: 3), isFinal: true)
    #expect(throws: VaultFileError.alreadyFinalized) { try finished.seal(chunk: Data(count: 3), isFinal: true) }
  }

  @Test("should reject misuse of the incremental opener")
  func shouldRejectOpenerMisuse() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let sealed = try VaultFile.seal(VaultFileFixtures.plaintext(count: 20), path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 8)
    let (header, chunks) = try VaultFileFixtures.split(sealed, chunkSize: 8)
    let ring = VaultFileFixtures.ring(key)

    #expect(throws: VaultFileError.trailingData) { try VaultFileOpener(header: header + Data([0]), path: VaultFileFixtures.path, vault: vault, keys: ring) }

    var short = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    #expect(throws: VaultFileError.invalidChunkLength) { try short.open(chunk: chunks[0].dropLast(), isFinal: false) }
    #expect(throws: VaultFileError.invalidChunkLength) { try short.open(chunk: chunks[0], isFinal: false) }

    var tiny = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    #expect(throws: VaultFileError.invalidChunkLength) { try tiny.open(chunk: Data(count: 15), isFinal: true) }

    var truncated = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    _ = try truncated.open(chunk: chunks[0], isFinal: false)
    #expect(throws: VaultFileError.truncated) { try truncated.finish() }

    var misflagged = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    #expect(throws: VaultFileError.authenticationFailed) { try misflagged.open(chunk: chunks[0], isFinal: true) }

    var poisoned = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    var corrupted = chunks[0]
    corrupted[0] ^= 1
    #expect(throws: VaultFileError.authenticationFailed) { try poisoned.open(chunk: corrupted, isFinal: false) }
    #expect(throws: VaultFileError.authenticationFailed) { try poisoned.open(chunk: chunks[0], isFinal: false) }
    #expect(throws: VaultFileError.authenticationFailed) { try poisoned.finish() }

    var complete = try VaultFileOpener(header: header, path: VaultFileFixtures.path, vault: vault, keys: ring)
    for (index, chunk) in chunks.enumerated() { _ = try complete.open(chunk: chunk, isFinal: index == chunks.count - 1) }
    #expect(throws: VaultFileError.trailingData) { try complete.open(chunk: chunks[2], isFinal: true) }
  }

  @Test("should allow 2^32 chunks and reject one more")
  func shouldBoundChunkCounter() throws {
    let key = try VaultFileFixtures.key()
    let vault = try VaultFileFixtures.vault()
    let lastIndex = UInt64(UInt32.max)

    var sealer = try VaultFileSealer(path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 4)
    sealer.cipher.state = .active(next: lastIndex)
    let lastChunk = try sealer.seal(chunk: Data([1, 2, 3, 4]), isFinal: false)
    #expect(throws: VaultFileError.tooManyChunks) { try sealer.seal(chunk: Data([5]), isFinal: true) }

    var opener = try VaultFileOpener(header: sealer.header, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
    opener.cipher.state = .active(next: lastIndex)
    #expect(try opener.open(chunk: lastChunk, isFinal: false) == Data([1, 2, 3, 4]))
    #expect(throws: VaultFileError.tooManyChunks) { try opener.open(chunk: lastChunk, isFinal: true) }

    var finalSealer = try VaultFileSealer(path: VaultFileFixtures.path, vault: vault, key: key, chunkSize: 4)
    finalSealer.cipher.state = .active(next: lastIndex)
    let finalChunk = try finalSealer.seal(chunk: Data([9]), isFinal: true)
    var finalOpener = try VaultFileOpener(header: finalSealer.header, path: VaultFileFixtures.path, vault: vault, keys: VaultFileFixtures.ring(key))
    finalOpener.cipher.state = .active(next: lastIndex)
    #expect(try finalOpener.open(chunk: finalChunk, isFinal: true) == Data([9]))
    try finalOpener.finish()
  }

  @Test("should round-trip random plaintexts, chunk sizes, paths and vaults")
  func shouldRoundTripRandomInputs() throws {
    try forAll(iterations: 150) { generator in
      let key = try VaultFileFixtures.key(byte: UInt8(truncatingIfNeeded: generator.next()))
      let vaultLength = generator.int(in: 1...VaultID.maximumLength)
      let vault = try VaultFileFixtures.vault(String((0..<vaultLength).map { _ in generator.pick(from: VaultFileFixtures.vaultCharacters) }))
      let path = generator.unicodeString(maxLength: 40)
      let chunkSize = generator.int(in: 1...300)
      let plaintext = generator.data(count: generator.int(in: 0...2_000))
      let sealed = try VaultFile.seal(plaintext, path: path, vault: vault, key: key, chunkSize: chunkSize)
      let header = try VaultFile.header(of: sealed)
      try #require(header == VaultFileHeader(formatVersion: 1, vault: vault, keyID: key.id, chunkSize: chunkSize, fileSalt: header.fileSalt, noncePrefix: header.noncePrefix))
      try #require(try VaultFile.open(sealed, path: path, vault: vault, keys: VaultFileFixtures.ring(key)) == plaintext)
    }
  }

  @Test("should never crash on arbitrary input")
  func shouldSurviveArbitraryInput() throws {
    let vault = try VaultFileFixtures.vault()
    let anyKey: (KeyID) -> VaultKey? = { id in VaultKey(id: id, rawBytes: Data(repeating: 0x42, count: 32)) }
    try forAll(iterations: 1_000) { generator in
      var data = generator.data(count: generator.int(in: 0...160))
      switch generator.int(in: 0...2) {
      case 0: data = VaultFormat.magic + Data([1, 0]) + data
      case 1:
        let key = try VaultFileFixtures.key()
        let sealer = try VaultFileSealer(path: "p", vault: vault, key: key, chunkSize: generator.int(in: 1...32))
        data = sealer.header + data
      default: break
      }
      _ = try? VaultFile.header(of: data)
      #expect(throws: VaultFileError.self) { try VaultFile.open(data, path: "p", vault: vault, keys: anyKey) }
    }
  }
}
