import CryptoKit
import Foundation
import Testing

@testable import ShadowSync

@Suite("Recovery wire format")
struct RecoveryWireFormatTests {
  private static let privateKey = "f1580fe43c01b42f9824137572e1f18b174fca5369abee92a26929ee791e26c8"
  private static let publicKey = "0983bbb9717e029bed085354249b8f11f8c72d34f53b0878f23a1ec88811ce7a"
  private static let sealingKey = "47f17e3d17bf77795911ee87846dc8fe4b42bc07f822903e710b7ebd5e5d75b1"
  private static let recipientID = "fc5b3aa851c68742"
  private static let keyID = "0193a1b2c3d47e5f8a6b7c8d9e0f1a2b"
  private static let ringKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

  private static func header() throws -> [UInt8] {
    [0x53, 0x4C, 0x4B, 0x31, 0x01, 0x00, 0x09] + Array("vault-one".utf8) + (try WireLiterals.hex(keyID))
  }

  private static let info = Data("SLV1/sealed-ring-key".utf8) + Data([0x00]) + Data("vault-one".utf8)

  private static func recoveryKey() throws -> RecoveryKey {
    RecoveryKey(secret: try #require(RecoverySecret(rawBytes: Data(0..<32))), vault: try #require(VaultID("vault-one")))
  }

  private static func handSealed(pskID: String = recipientID, associatedData: [UInt8]? = nil) throws -> Data {
    let header = try header()
    var sender = try HPKE.Sender(
      recipientKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: try WireLiterals.hex(publicKey)), ciphersuite: WireLiterals.suite, info: info,
      presharedKey: SymmetricKey(data: try WireLiterals.hex(sealingKey)), presharedKeyIdentifier: Data(pskID.utf8))
    let ciphertext = try sender.seal(try WireLiterals.hex(ringKey), authenticating: associatedData ?? header)
    return Data(header) + sender.encapsulatedKey + ciphertext
  }

  @Test("should open a recovery copy built by hand from literals and plain CryptoKit")
  func shouldOpenHandBuiltCopy() throws {
    let sealed = try Self.handSealed()
    #expect(sealed.count == 112)
    let key = try SealedRingKey.open(sealed, with: try Self.recoveryKey(), vault: try #require(VaultID("vault-one")))
    #expect(key.id.description == "0193a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b")
    #expect(Array(key.rawBytes) == (try WireLiterals.hex(Self.ringKey)))
  }

  @Test("should seal a copy that a hand-written HPKE recipient opens with the same literals")
  func shouldSealCopyThatOpensByHand() throws {
    let recipient = try #require(RecoveryRecipient(publicKey: Data(try WireLiterals.hex(Self.publicKey)), sealingKey: Data(try WireLiterals.hex(Self.sealingKey))))
    #expect(recipient == (try Self.recoveryKey()).recipient)
    #expect(recipient.id == Self.recipientID)
    let keyID = try #require(KeyID("0193a1b2-c3d4-7e5f-8a6b-7c8d9e0f1a2b"))
    let vault = try #require(VaultID("vault-one"))
    let key = try #require(VaultKey(id: keyID, rawBytes: Data(try WireLiterals.hex(Self.ringKey))))
    let sealed = Array(try SealedRingKey.seal(key, to: recipient, vault: vault))
    try #require(sealed.count == 112)
    #expect(Array(sealed.prefix(32)) == (try Self.header()))
    var opener = try HPKE.Recipient(
      privateKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try WireLiterals.hex(Self.privateKey)), ciphersuite: WireLiterals.suite,
      info: Self.info, encapsulatedKey: Data(sealed[32..<64]), presharedKey: SymmetricKey(data: try WireLiterals.hex(Self.sealingKey)),
      presharedKeyIdentifier: Data(Self.recipientID.utf8))
    #expect(Array(try opener.open(Data(sealed[64...]), authenticating: try Self.header())) == (try WireLiterals.hex(Self.ringKey)))
  }

  @Test("should reject a hand-built copy with another psk id or associated data range")
  func shouldRejectOffSpecCopies() throws {
    let vault = try #require(VaultID("vault-one"))
    let recovery = try Self.recoveryKey()
    let header = try Self.header()
    for sealed in [
      try Self.handSealed(pskID: "fc5b3aa851c68743"),
      try Self.handSealed(associatedData: Array(header.prefix(31))),
      try Self.handSealed(associatedData: Array(header.dropFirst(4))),
    ] {
      #expect(throws: KeyEnvelopeError.authenticationFailed) { try SealedRingKey.open(sealed, with: recovery, vault: vault) }
    }
  }
}
