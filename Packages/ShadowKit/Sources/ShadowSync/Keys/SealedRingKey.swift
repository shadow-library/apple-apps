import CryptoKit
import Foundation

public enum SealedRingKey {
  static let magic = Array("SLK1".utf8)
  static let version: UInt8 = 1
  static let encapsulatedKeyLength = 32
  static let ciphertextLength = VaultKey.byteCount + 16
  static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
  private static let infoContext = Data("SLV1/sealed-ring-key".utf8)

  public static func seal(_ key: VaultKey, to recipient: RecoveryRecipient, vault: VaultID) throws(KeyEnvelopeError) -> Data {
    let header = header(vault: vault, keyID: key.id)
    do {
      let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey)
      var sender = try HPKE.Sender(
        recipientKey: publicKey, ciphersuite: ciphersuite, info: info(vault: vault), presharedKey: SymmetricKey(data: recipient.sealingKey),
        presharedKeyIdentifier: Data(recipient.id.utf8))
      let ciphertext = try sender.seal(key.rawBytes, authenticating: header)
      guard sender.encapsulatedKey.count == encapsulatedKeyLength, ciphertext.count == ciphertextLength else { throw KeyEnvelopeError.cryptoFailure }
      return header + sender.encapsulatedKey + ciphertext
    } catch {
      throw .cryptoFailure
    }
  }

  public static func open(_ sealed: Data, with recovery: RecoveryKey, vault: VaultID) throws(KeyEnvelopeError) -> VaultKey {
    let envelope = try Envelope.parse(sealed)
    guard envelope.vault == vault else { throw .vaultMismatch(expected: vault, found: envelope.vault) }
    guard recovery.vault == vault else { throw .vaultMismatch(expected: vault, found: recovery.vault) }
    let opened: Data
    do {
      var recipient = try HPKE.Recipient(
        privateKey: recovery.privateKey, ciphersuite: ciphersuite, info: info(vault: vault), encapsulatedKey: envelope.encapsulatedKey,
        presharedKey: recovery.sealingKey, presharedKeyIdentifier: Data(recovery.recipient.id.utf8))
      opened = try recipient.open(envelope.ciphertext, authenticating: envelope.header)
    } catch {
      throw .authenticationFailed
    }
    guard let key = VaultKey(id: envelope.keyID, rawBytes: opened), key.id == envelope.keyID else { throw .malformed }
    return key
  }

  /// Unauthenticated: use it to route a copy, never to decide which key a file or a ring holds.
  public static func keyID(of sealed: Data) throws(KeyEnvelopeError) -> KeyID {
    try Envelope.parse(sealed).keyID
  }

  public static func path(recipient: RecoveryRecipient, key: KeyID) -> String {
    "keys/\(recipient.id)/\(key)"
  }

  static func header(vault: VaultID, keyID: KeyID) -> Data {
    let vaultBytes = Array(vault.rawValue.utf8)
    var data = Data(magic)
    data.append(version)
    data.append(bigEndian: UInt16(vaultBytes.count))
    data.append(contentsOf: vaultBytes)
    data.append(contentsOf: keyID.bytes)
    return data
  }

  static func info(vault: VaultID) -> Data {
    infoContext + Data([0]) + Data(vault.rawValue.utf8)
  }

  private struct Envelope {
    let vault: VaultID
    let keyID: KeyID
    let header: Data
    let encapsulatedKey: Data
    let ciphertext: Data

    static func parse(_ sealed: Data) throws(KeyEnvelopeError) -> Envelope {
      let bytes = [UInt8](sealed)
      var reader = ByteReader(bytes)
      guard reader.read(magic.count) == magic else { throw .malformed }
      guard let version = reader.readByte() else { throw .malformed }
      guard version == SealedRingKey.version else { throw .unsupportedVersion(version) }
      guard let vaultLength = reader.readUInt16().map(Int.init), (1...VaultID.maximumLength).contains(vaultLength) else { throw .malformed }
      guard reader.remaining == vaultLength + 16 + encapsulatedKeyLength + ciphertextLength else { throw .malformed }
      guard let vault = reader.readVaultID(length: vaultLength) else { throw .malformed }
      guard let keyID = reader.readKeyID(), let encapsulatedKey = reader.read(encapsulatedKeyLength), let ciphertext = reader.read(ciphertextLength) else {
        throw .malformed
      }
      let headerLength = bytes.count - encapsulatedKeyLength - ciphertextLength
      return Envelope(vault: vault, keyID: keyID, header: Data(bytes[0..<headerLength]), encapsulatedKey: Data(encapsulatedKey), ciphertext: Data(ciphertext))
    }
  }
}
