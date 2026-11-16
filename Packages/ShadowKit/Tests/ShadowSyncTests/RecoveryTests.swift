import CryptoKit
import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowSync

@Suite("Recovery")
struct RecoveryTests {
  private static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

  private static func vault(_ raw: String = "vault-one") throws -> VaultID {
    try #require(VaultID(raw))
  }

  private static func secret(_ bytes: Data = Data(0..<32)) throws -> RecoverySecret {
    try #require(RecoverySecret(rawBytes: bytes))
  }

  private static func ringKey(byte: UInt8 = 0x5A) throws -> VaultKey {
    try #require(VaultKey(id: KeyID(UUID.v7()), rawBytes: Data(repeating: byte, count: 32)))
  }

  private static func hex(_ text: String) throws -> Data {
    let digits = Array(text.utf8)
    try #require(digits.count.isMultiple(of: 2))
    return Data(
      try stride(from: 0, to: digits.count, by: 2).map { index in
        try #require(UInt8(String(decoding: digits[index...(index + 1)], as: UTF8.self), radix: 16))
      })
  }

  @Test("should accept exactly 32 secret bytes and generate distinct secrets")
  func shouldValidateSecret() throws {
    #expect(RecoverySecret(rawBytes: Data(count: 31)) == nil)
    #expect(RecoverySecret(rawBytes: Data(count: 33)) == nil)
    #expect(try Self.secret().rawBytes == Data(0..<32))
    #expect(RecoverySecret.generate().rawBytes.count == RecoverySecret.byteCount)
    #expect(RecoverySecret.generate().rawBytes != RecoverySecret.generate().rawBytes)
  }

  @Test("should round-trip a ring key through a recovery copy")
  func shouldRoundTrip() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    let key = try Self.ringKey()
    let sealed = try SealedRingKey.seal(key, to: recovery.recipient, vault: vault)
    #expect(sealed.count == 103 + vault.rawValue.utf8.count)
    #expect(sealed.prefix(4) == Data("SLK1".utf8))
    #expect(try SealedRingKey.keyID(of: sealed) == key.id)
    let opened = try SealedRingKey.open(sealed, with: recovery, vault: vault)
    #expect(opened.id == key.id)
    #expect(opened.rawBytes == key.rawBytes)
    #expect(try SealedRingKey.seal(key, to: recovery.recipient, vault: vault) != sealed)
  }

  @Test("should derive the pinned recipient for a fixed secret and vault")
  func shouldMatchKnownAnswer() throws {
    let vault = try Self.vault()
    let secret = try Self.secret()
    let recipient = RecoveryKey(secret: secret, vault: vault).recipient

    let input = SymmetricKey(data: Data(0..<32))
    let salt = Data("vault-one".utf8)
    let privateBytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("SLV1/recovery/x25519".utf8), outputByteCount: 32)
    let sealingKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: Data("SLV1/recovery/psk".utf8), outputByteCount: 32)
    let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes.withUnsafeBytes { Data($0) })
    let digest = SHA256.hash(data: Data("SLV1/recovery-id".utf8) + Data([0]) + privateKey.publicKey.rawRepresentation)

    #expect(recipient.publicKey == privateKey.publicKey.rawRepresentation)
    #expect(recipient.sealingKey == sealingKey.withUnsafeBytes { Data($0) })
    #expect(recipient.id == String(lowercaseHex(digest).prefix(16)))

    #expect(privateBytes.withUnsafeBytes { Data($0) } == (try Self.hex("f1580fe43c01b42f9824137572e1f18b174fca5369abee92a26929ee791e26c8")))
    #expect(recipient.publicKey == (try Self.hex("0983bbb9717e029bed085354249b8f11f8c72d34f53b0878f23a1ec88811ce7a")))
    #expect(recipient.sealingKey == (try Self.hex("47f17e3d17bf77795911ee87846dc8fe4b42bc07f822903e710b7ebd5e5d75b1")))
    #expect(recipient.id == "fc5b3aa851c68742")
    #expect(
      SealedRingKey.path(recipient: recipient, key: try #require(KeyID("01930000-0000-7000-8000-000000000001")))
        == "keys/fc5b3aa851c68742/01930000-0000-7000-8000-000000000001")
  }

  @Test("should give the same secret a different recipient in each vault")
  func shouldSeparateVaults() throws {
    let secret = try Self.secret()
    let first = RecoveryKey(secret: secret, vault: try Self.vault("vault-one")).recipient
    let second = RecoveryKey(secret: secret, vault: try Self.vault("vault-two")).recipient
    #expect(first.publicKey != second.publicKey)
    #expect(first.sealingKey != second.sealingKey)
    #expect(first.id != second.id)
  }

  @Test("should refuse a wrong secret or a wrong vault")
  func shouldRefuseWrongSecretOrVault() throws {
    let vault = try Self.vault()
    let other = try Self.vault("vault-two")
    let secret = RecoverySecret.generate()
    let sealed = try SealedRingKey.seal(try Self.ringKey(), to: RecoveryKey(secret: secret, vault: vault).recipient, vault: vault)
    #expect(throws: KeyEnvelopeError.authenticationFailed) {
      try SealedRingKey.open(sealed, with: RecoveryKey(secret: RecoverySecret.generate(), vault: vault), vault: vault)
    }
    #expect(throws: KeyEnvelopeError.vaultMismatch(expected: other, found: vault)) {
      try SealedRingKey.open(sealed, with: RecoveryKey(secret: secret, vault: other), vault: other)
    }
    #expect(throws: KeyEnvelopeError.vaultMismatch(expected: vault, found: other)) {
      try SealedRingKey.open(sealed, with: RecoveryKey(secret: secret, vault: other), vault: vault)
    }
    let foreign = try SealedRingKey.seal(try Self.ringKey(), to: RecoveryKey(secret: secret, vault: other).recipient, vault: other)
    #expect(throws: KeyEnvelopeError.vaultMismatch(expected: vault, found: other)) {
      try SealedRingKey.open(foreign, with: RecoveryKey(secret: secret, vault: vault), vault: vault)
    }
  }

  @Test("should reject every single-bit flip of an envelope")
  func shouldRejectBitFlips() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    let sealed = try SealedRingKey.seal(try Self.ringKey(), to: recovery.recipient, vault: vault)
    for index in 0..<sealed.count {
      for bit in 0..<8 {
        var flipped = sealed
        flipped[index] ^= 1 << bit
        #expect(throws: KeyEnvelopeError.self, "byte \(index) bit \(bit)") { try SealedRingKey.open(flipped, with: recovery, vault: vault) }
      }
    }
  }

  @Test("should reject every truncation and any trailing byte without trapping")
  func shouldRejectTruncation() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    let sealed = try SealedRingKey.seal(try Self.ringKey(), to: recovery.recipient, vault: vault)
    for length in 0..<sealed.count {
      let truncated = sealed.prefix(length)
      #expect(throws: KeyEnvelopeError.malformed, "length \(length)") { try SealedRingKey.open(truncated, with: recovery, vault: vault) }
      #expect(throws: KeyEnvelopeError.malformed, "length \(length)") { try SealedRingKey.keyID(of: truncated) }
    }
    #expect(throws: KeyEnvelopeError.malformed) { try SealedRingKey.open(sealed + Data([0]), with: recovery, vault: vault) }
    let sliced = (Data([9, 9]) + sealed).dropFirst(2)
    #expect(try SealedRingKey.open(sliced, with: recovery, vault: vault).rawBytes == Data(repeating: 0x5A, count: 32))
  }

  @Test("should report an unknown version")
  func shouldRejectUnknownVersion() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    var sealed = try SealedRingKey.seal(try Self.ringKey(), to: recovery.recipient, vault: vault)
    sealed[4] = 2
    #expect(throws: KeyEnvelopeError.unsupportedVersion(2)) { try SealedRingKey.open(sealed, with: recovery, vault: vault) }
  }

  @Test("should refuse a copy forged in HPKE base mode from the public key alone")
  func shouldRefuseBaseModeForgery() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    let forgedKeyID = try #require(KeyID("00000000-0000-7000-8000-000000000000"))
    let header = SealedRingKey.header(vault: vault, keyID: forgedKeyID)
    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recovery.recipient.publicKey)
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: Self.suite, info: SealedRingKey.info(vault: vault))
    let ciphertext = try sender.seal(Data(repeating: 0x66, count: 32), authenticating: header)
    let forged = header + sender.encapsulatedKey + ciphertext
    #expect(try SealedRingKey.keyID(of: forged) == forgedKeyID)
    #expect(throws: KeyEnvelopeError.authenticationFailed) { try SealedRingKey.open(forged, with: recovery, vault: vault) }
  }

  @Test("should refuse a copy sealed with the right public key and a wrong sealing key")
  func shouldRefuseWrongSealingKey() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: RecoverySecret.generate(), vault: vault)
    let wrong = try #require(RecoveryRecipient(publicKey: recovery.recipient.publicKey, sealingKey: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }))
    #expect(wrong.id == recovery.recipient.id)
    let sealed = try SealedRingKey.seal(try Self.ringKey(), to: wrong, vault: vault)
    #expect(throws: KeyEnvelopeError.authenticationFailed) { try SealedRingKey.open(sealed, with: recovery, vault: vault) }
  }

  @Test("should refuse to seal to a low-order public key")
  func shouldRefuseLowOrderKey() throws {
    let recipient = try #require(RecoveryRecipient(publicKey: Data(count: 32), sealingKey: Data(repeating: 1, count: 32)))
    #expect(throws: KeyEnvelopeError.cryptoFailure) { try SealedRingKey.seal(try Self.ringKey(), to: recipient, vault: try Self.vault()) }
  }

  @Test("should validate and round-trip a recipient through Codable")
  func shouldCodeRecipient() throws {
    let recipient = RecoveryKey(secret: try Self.secret(), vault: try Self.vault()).recipient
    #expect(RecoveryRecipient(publicKey: Data(count: 31), sealingKey: Data(count: 32)) == nil)
    #expect(RecoveryRecipient(publicKey: Data(count: 32), sealingKey: Data(count: 33)) == nil)
    let encoded = try JSONEncoder().encode(recipient)
    #expect(try JSONDecoder().decode(RecoveryRecipient.self, from: encoded) == recipient)
    let otherSealingKey = try #require(RecoveryRecipient(publicKey: recipient.publicKey, sealingKey: Data(repeating: 0, count: 32)))
    #expect(otherSealingKey != recipient)
    #expect(RecoveryRecipient(publicKey: recipient.publicKey, sealingKey: recipient.sealingKey) == recipient)
    let short = Data(#"{"publicKey":"AAAA","sealingKey":"AAAA"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(RecoveryRecipient.self, from: short) }
  }

  @Test("should never show secret bytes when described")
  func shouldNotLeakSecrets() throws {
    let secret = try Self.secret(Data(repeating: 0xAB, count: 32))
    let recovery = RecoveryKey(secret: secret, vault: try Self.vault())
    let sealingHex = lowercaseHex(recovery.recipient.sealingKey)
    let texts = [
      String(describing: secret), String(reflecting: secret), "\(secret)",
      String(describing: recovery), String(reflecting: recovery), "\(recovery)",
      String(describing: recovery.recipient), String(reflecting: recovery.recipient),
    ]
    for text in texts {
      #expect(!text.lowercased().contains("abab"))
      #expect(!text.contains("171"))
      #expect(!text.contains("q6ur"))
      #expect(!text.contains(sealingHex.prefix(8)))
      #expect(!text.contains("bytes"))
    }
    #expect(Mirror(reflecting: secret).children.isEmpty)
    #expect(Mirror(reflecting: recovery).children.map(\.label) == ["vault", "recipient"])
    #expect(Mirror(reflecting: recovery.recipient).children.map(\.label) == ["id"])
  }

  @Test("should never trap on random bytes")
  func shouldSurviveRandomBytes() throws {
    let vault = try Self.vault()
    let recovery = RecoveryKey(secret: try Self.secret(), vault: vault)
    let valid = try SealedRingKey.seal(try Self.ringKey(), to: recovery.recipient, vault: vault)
    try forAll(iterations: 500) { generator in
      var bytes = generator.data(count: generator.int(in: 0...200))
      if generator.chance(0.5) { bytes = valid.prefix(generator.int(in: 0...valid.count)) + bytes }
      if generator.chance(0.25) { bytes = Data("SLK1".utf8) + Data([1, 0, UInt8(vault.rawValue.utf8.count)]) + Data(vault.rawValue.utf8) + bytes }
      _ = try? SealedRingKey.keyID(of: bytes)
      guard bytes != valid else { return }
      #expect(throws: KeyEnvelopeError.self) { try SealedRingKey.open(bytes, with: recovery, vault: vault) }
    }
  }
}
