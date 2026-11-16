import CryptoKit
import Foundation

public struct RecoverySecret: Sendable {
  public static let byteCount = 32

  let symmetricKey: SymmetricKey

  public init?(rawBytes: Data) {
    guard rawBytes.count == Self.byteCount else { return nil }
    symmetricKey = SymmetricKey(data: rawBytes)
  }

  private init(symmetricKey: SymmetricKey) {
    self.symmetricKey = symmetricKey
  }

  public static func generate() -> RecoverySecret {
    RecoverySecret(symmetricKey: SymmetricKey(size: .bits256))
  }

  public var rawBytes: Data {
    symmetricKey.withUnsafeBytes { Data($0) }
  }
}

extension RecoverySecret: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: [], displayStyle: .struct)
  }
}

/// Store only inside sealed vault state. The sealing key lets its holder forge recovery copies, so it must never reach the storage provider in the clear.
public struct RecoveryRecipient: Sendable, Equatable, Codable {
  private static let idContext = Data("SLV1/recovery-id".utf8) + Data([0])
  static let keyByteCount = 32

  public let publicKey: Data
  public let sealingKey: Data

  public init?(publicKey: Data, sealingKey: Data) {
    guard publicKey.count == Self.keyByteCount, sealingKey.count == Self.keyByteCount else { return nil }
    self.publicKey = Data(publicKey)
    self.sealingKey = Data(sealingKey)
  }

  public var id: String {
    String(lowercaseHex(SHA256.hash(data: Self.idContext + publicKey)).prefix(16))
  }

  public static func == (lhs: RecoveryRecipient, rhs: RecoveryRecipient) -> Bool {
    let samePublicKey = lhs.publicKey == rhs.publicKey
    let sameSealingKey = constantTimeEquals(lhs.sealingKey, rhs.sealingKey)
    return samePublicKey && sameSealingKey
  }

  private enum CodingKeys: String, CodingKey {
    case publicKey
    case sealingKey
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let publicKey = try container.decode(Data.self, forKey: .publicKey)
    let sealingKey = try container.decode(Data.self, forKey: .sealingKey)
    guard let recipient = RecoveryRecipient(publicKey: publicKey, sealingKey: sealingKey) else {
      throw DecodingError.dataCorruptedError(forKey: .publicKey, in: container, debugDescription: "Recovery keys must be 32 bytes each")
    }
    self = recipient
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(publicKey, forKey: .publicKey)
    try container.encode(sealingKey, forKey: .sealingKey)
  }
}

extension RecoveryRecipient: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["id": id], displayStyle: .struct)
  }
}

public struct RecoveryKey: Sendable {
  static let privateKeyInfo = Data("SLV1/recovery/x25519".utf8)
  static let sealingKeyInfo = Data("SLV1/recovery/psk".utf8)

  let vault: VaultID
  let privateKey: Curve25519.KeyAgreement.PrivateKey
  let sealingKey: SymmetricKey
  public let recipient: RecoveryRecipient

  public init(secret: RecoverySecret, vault: VaultID) {
    let salt = Data(vault.rawValue.utf8)
    let privateBytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.symmetricKey, salt: salt, info: Self.privateKeyInfo, outputByteCount: 32)
    let sealingKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: secret.symmetricKey, salt: salt, info: Self.sealingKeyInfo, outputByteCount: 32)
    guard let privateKey = try? privateBytes.withUnsafeBytes({ try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }) else {
      preconditionFailure("X25519 accepts every 32-byte private key")
    }
    let sealingBytes = sealingKey.withUnsafeBytes { Data($0) }
    guard let recipient = RecoveryRecipient(publicKey: privateKey.publicKey.rawRepresentation, sealingKey: sealingBytes) else {
      preconditionFailure("derived recovery keys are 32 bytes")
    }
    self.vault = vault
    self.privateKey = privateKey
    self.sealingKey = sealingKey
    self.recipient = recipient
  }
}

extension RecoveryKey: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["vault": vault, "recipient": recipient.id], displayStyle: .struct)
  }
}
