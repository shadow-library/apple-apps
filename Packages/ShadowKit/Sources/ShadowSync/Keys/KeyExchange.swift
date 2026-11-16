import CryptoKit
import Foundation
import Synchronization

enum KeyExchangeCode {
  static let textPrefix = "SLX1:"
  static let version: UInt8 = 1
  static let requestKind: UInt8 = 1
  static let responseKind: UInt8 = 2
  static let checksumLength = 4
  static let publicKeyLength = 32
  static let encapsulatedKeyLength = 32
  static let associatedDataLength = 18
  static let maximumTextLength = 2_048
  static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
  private static let infoContext = Data("SLV1/key-exchange".utf8)
  private static let confirmationContext = Data("SLV1/key-exchange/confirm".utf8)

  static func encode(_ payload: [UInt8]) -> String {
    textPrefix + Base32.encode(payload + checksum(payload))
  }

  static func decode(_ text: String, kind: UInt8) throws(KeyEnvelopeError) -> [UInt8] {
    let characters = text.utf8
    let prefix = textPrefix.utf8
    guard characters.count <= maximumTextLength, characters.starts(with: prefix) else { throw .corruptText }
    guard let bytes = Base32.decode(characters.dropFirst(prefix.count)), bytes.count > associatedDataLength + checksumLength else { throw .corruptText }
    let payload = Array(bytes.dropLast(checksumLength))
    guard checksum(payload) == Array(bytes.suffix(checksumLength)) else { throw .corruptText }
    guard payload[0] == version else { throw .unsupportedVersion(payload[0]) }
    guard payload[1] == kind else { throw .unexpectedKind(payload[1]) }
    return payload
  }

  static func info(requestID: UUID, publicKey: Data) -> Data {
    infoContext + Data([0]) + uuidBytes(requestID) + publicKey
  }

  static func associatedData(requestID: UUID) -> Data {
    Data([version, responseKind]) + uuidBytes(requestID)
  }

  static func uuidBytes(_ uuid: UUID) -> Data {
    withUnsafeBytes(of: uuid.uuid) { Data($0) }
  }

  static func uuid(_ bytes: [UInt8]) -> UUID {
    KeyID(bytes: bytes).uuid
  }

  static func confirmationCode(_ secret: SymmetricKey) -> String {
    let value = secret.withUnsafeBytes { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    let digits = String(value % 1_000_000)
    return String(repeating: "0", count: 6 - digits.count) + digits
  }

  static func exportConfirmation(_ export: (Data) throws -> SymmetricKey) throws(KeyEnvelopeError) -> String {
    do {
      return confirmationCode(try export(confirmationContext))
    } catch {
      throw .cryptoFailure
    }
  }

  private static func checksum(_ payload: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: payload).prefix(checksumLength))
  }
}

public struct KeyExchangeRequest: Sendable, Equatable {
  private static let payloadLength = 2 + 16 + KeyExchangeCode.publicKeyLength

  public let id: UUID
  public let publicKey: Data

  init?(id: UUID, publicKey: Data) {
    guard publicKey.count == KeyExchangeCode.publicKeyLength else { return nil }
    self.id = id
    self.publicKey = Data(publicKey)
  }

  public init(encoded: String) throws(KeyEnvelopeError) {
    var reader = ByteReader(try KeyExchangeCode.decode(encoded, kind: KeyExchangeCode.requestKind))
    guard reader.remaining == Self.payloadLength, reader.read(2) != nil, let id = reader.read(16), let publicKey = reader.read(KeyExchangeCode.publicKeyLength) else {
      throw .malformed
    }
    guard let request = KeyExchangeRequest(id: KeyExchangeCode.uuid(id), publicKey: Data(publicKey)) else { throw .malformed }
    self = request
  }

  public var encoded: String {
    KeyExchangeCode.encode([KeyExchangeCode.version, KeyExchangeCode.requestKind] + KeyExchangeCode.uuidBytes(id) + publicKey)
  }
}

/// Single use: one request answers one response, so after one decryption attempt, successful or not, every further `open` throws `sessionSpent`.
public final class KeyExchangeSession: Sendable {
  private let privateKey: Curve25519.KeyAgreement.PrivateKey
  private let isSpent = Mutex(false)
  public let request: KeyExchangeRequest

  public init() {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    guard let request = KeyExchangeRequest(id: UUID(), publicKey: privateKey.publicKey.rawRepresentation) else {
      preconditionFailure("an X25519 public key is 32 bytes")
    }
    self.privateKey = privateKey
    self.request = request
  }

  public func open(_ response: KeyExchangeResponse, expecting vault: VaultID? = nil) throws(KeyEnvelopeError) -> KeyExchangeResult {
    guard response.requestID == request.id else { throw .requestMismatch }
    let wasSpent = isSpent.withLock { isSpent in
      defer { isSpent = true }
      return isSpent
    }
    guard !wasSpent else { throw .sessionSpent }
    let plaintext: Data
    let confirmationCode: String
    do {
      var recipient = try HPKE.Recipient(
        privateKey: privateKey, ciphersuite: KeyExchangeCode.ciphersuite, info: KeyExchangeCode.info(requestID: request.id, publicKey: request.publicKey),
        encapsulatedKey: response.encapsulatedKey)
      plaintext = try recipient.open(response.ciphertext, authenticating: KeyExchangeCode.associatedData(requestID: request.id))
      confirmationCode = try KeyExchangeCode.exportConfirmation { try recipient.exportSecret(context: $0, outputByteCount: 4) }
    } catch {
      throw .authenticationFailed
    }
    let (sealedVault, keys) = try KeyExchangeResponse.parsePlaintext(plaintext)
    if let vault, vault != sealedVault { throw .vaultMismatch(expected: vault, found: sealedVault) }
    return KeyExchangeResult(vault: sealedVault, keys: keys, confirmationCode: confirmationCode)
  }
}

extension KeyExchangeSession: CustomReflectable {
  public var customMirror: Mirror {
    Mirror(self, children: ["request": request.id], displayStyle: .class)
  }
}

/// The keys are candidates, and the vault id is whatever the responder claimed: anyone who saw the request can make a response that opens.
/// Add a key to the ring only after the user has confirmed that both screens show the same code and the key has opened a file the vault already holds.
public struct KeyExchangeResult: Sendable {
  public let vault: VaultID
  public let keys: [VaultKey]
  public let confirmationCode: String
}

public struct KeyExchangeResponse: Sendable, Equatable {
  public static let maximumKeys = 16
  private static let keyEntryLength = 16 + VaultKey.byteCount
  private static let tagLength = 16
  private static let minimumCiphertextLength = 1 + 1 + 1 + keyEntryLength + tagLength
  private static let maximumCiphertextLength = 1 + VaultID.maximumLength + 1 + maximumKeys * keyEntryLength + tagLength

  let requestID: UUID
  let encapsulatedKey: Data
  let ciphertext: Data

  public static func make(answering request: KeyExchangeRequest, vault: VaultID, keys: [VaultKey]) throws(KeyEnvelopeError) -> (
    response: KeyExchangeResponse, confirmationCode: String
  ) {
    guard (1...maximumKeys).contains(keys.count) else { throw .invalidKeyCount(keys.count) }
    var seen: Set<KeyID> = []
    for key in keys where !seen.insert(key.id).inserted { throw .duplicateKeyID(key.id) }
    let vaultBytes = Array(vault.rawValue.utf8)
    var plaintext = Data([UInt8(vaultBytes.count)]) + vaultBytes + [UInt8(keys.count)]
    for key in keys { plaintext += key.id.bytes + key.rawBytes }
    do {
      let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.publicKey)
      var sender = try HPKE.Sender(
        recipientKey: publicKey, ciphersuite: KeyExchangeCode.ciphersuite, info: KeyExchangeCode.info(requestID: request.id, publicKey: request.publicKey))
      let ciphertext = try sender.seal(plaintext, authenticating: KeyExchangeCode.associatedData(requestID: request.id))
      let code = try KeyExchangeCode.exportConfirmation { try sender.exportSecret(context: $0, outputByteCount: 4) }
      return (KeyExchangeResponse(requestID: request.id, encapsulatedKey: sender.encapsulatedKey, ciphertext: ciphertext), code)
    } catch {
      throw .cryptoFailure
    }
  }

  public init(encoded: String) throws(KeyEnvelopeError) {
    var reader = ByteReader(try KeyExchangeCode.decode(encoded, kind: KeyExchangeCode.responseKind))
    guard reader.read(2) != nil, let id = reader.read(16), let encapsulatedKey = reader.read(KeyExchangeCode.encapsulatedKeyLength) else { throw .malformed }
    guard (Self.minimumCiphertextLength...Self.maximumCiphertextLength).contains(reader.remaining), let ciphertext = reader.read(reader.remaining) else {
      throw .malformed
    }
    requestID = KeyExchangeCode.uuid(id)
    self.encapsulatedKey = Data(encapsulatedKey)
    self.ciphertext = Data(ciphertext)
  }

  private init(requestID: UUID, encapsulatedKey: Data, ciphertext: Data) {
    self.requestID = requestID
    self.encapsulatedKey = encapsulatedKey
    self.ciphertext = ciphertext
  }

  public var encoded: String {
    KeyExchangeCode.encode([KeyExchangeCode.version, KeyExchangeCode.responseKind] + KeyExchangeCode.uuidBytes(requestID) + encapsulatedKey + ciphertext)
  }

  static func parsePlaintext(_ plaintext: Data) throws(KeyEnvelopeError) -> (VaultID, [VaultKey]) {
    var reader = ByteReader([UInt8](plaintext))
    guard let vaultLength = reader.readByte(), let vault = reader.readVaultID(length: Int(vaultLength)), let count = reader.readByte().map(Int.init) else {
      throw .malformed
    }
    guard (1...maximumKeys).contains(count) else { throw .invalidKeyCount(count) }
    guard reader.remaining == count * keyEntryLength else { throw .malformed }
    var keys: [VaultKey] = []
    var seen: Set<KeyID> = []
    for _ in 0..<count {
      guard let id = reader.readKeyID(), let bytes = reader.read(VaultKey.byteCount), let key = VaultKey(id: id, rawBytes: Data(bytes)) else { throw .malformed }
      guard seen.insert(id).inserted else { throw .duplicateKeyID(id) }
      keys.append(key)
    }
    return (vault, keys)
  }
}
