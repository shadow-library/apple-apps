import CryptoKit
import Foundation
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

@Suite("KeyExchange")
struct KeyExchangeTests {
  private static let qrAlphanumeric = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
  private static let substitutes = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567a1:=")

  private static func vault(_ raw: String = "vault-one") throws -> VaultID {
    try #require(VaultID(raw))
  }

  private static func keys(_ count: Int) -> [VaultKey] {
    (0..<count).map { _ in VaultKey.generate(id: KeyID(UUID.v7())) }
  }

  private static func transmit(_ request: KeyExchangeRequest) throws -> KeyExchangeRequest {
    try KeyExchangeRequest(encoded: request.encoded)
  }

  private static func transmit(_ response: KeyExchangeResponse) throws -> KeyExchangeResponse {
    try KeyExchangeResponse(encoded: response.encoded)
  }

  @Test("should carry 1 or 16 keys from the ring to the new device", arguments: [1, 16])
  func shouldRoundTrip(count: Int) throws {
    let vault = try Self.vault(String(repeating: "v", count: VaultID.maximumLength))
    let session = KeyExchangeSession()
    let scanned = try Self.transmit(session.request)
    #expect(scanned == session.request)
    let keys = Self.keys(count)
    let (response, responderCode) = try KeyExchangeResponse.make(answering: scanned, vault: vault, keys: keys)
    let result = try session.open(try Self.transmit(response), expecting: vault)
    #expect(result.vault == vault)
    #expect(result.keys.map(\.id) == keys.map(\.id))
    #expect(result.keys.map(\.rawBytes) == keys.map(\.rawBytes))
    #expect(result.confirmationCode == responderCode)
    #expect(result.confirmationCode.count == 6)
    #expect(result.confirmationCode.allSatisfy(\.isASCII) && result.confirmationCode.allSatisfy(\.isNumber))
    #expect(throws: KeyEnvelopeError.sessionSpent) { try session.open(response) }
  }

  @Test("should reject 0 and 17 keys and duplicate key ids")
  func shouldRejectKeyCounts() throws {
    let request = KeyExchangeSession().request
    let vault = try Self.vault()
    #expect(throws: KeyEnvelopeError.invalidKeyCount(0)) { try KeyExchangeResponse.make(answering: request, vault: vault, keys: []) }
    #expect(throws: KeyEnvelopeError.invalidKeyCount(17)) { try KeyExchangeResponse.make(answering: request, vault: vault, keys: Self.keys(17)) }
    let key = VaultKey.generate(id: KeyID(UUID.v7()))
    #expect(throws: KeyEnvelopeError.duplicateKeyID(key.id)) { try KeyExchangeResponse.make(answering: request, vault: vault, keys: [key, key]) }
  }

  @Test("should reject sealed plaintexts that are malformed or carry a bad key count")
  func shouldRejectBadPlaintext() throws {
    let entry = [UInt8](repeating: 1, count: 48)
    let vault = Array("v".utf8)
    #expect(throws: KeyEnvelopeError.invalidKeyCount(0)) { try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [0])) }
    #expect(throws: KeyEnvelopeError.invalidKeyCount(17)) { try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [17] + Array(repeating: entry, count: 17).joined())) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [2] + entry)) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [1] + entry + [0])) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse.parsePlaintext(Data([0, 1] + entry)) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse.parsePlaintext(Data([1] + Array("V".utf8) + [1] + entry)) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse.parsePlaintext(Data()) }
    #expect(throws: KeyEnvelopeError.duplicateKeyID(KeyID(bytes: entry.prefix(16)))) {
      try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [2] + entry + entry))
    }
    #expect(try KeyExchangeResponse.parsePlaintext(Data([1] + vault + [1] + entry)).1.count == 1)
  }

  @Test("should refuse a response opened by another session")
  func shouldRefuseOtherSession() throws {
    let session = KeyExchangeSession()
    let (response, _) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1))
    #expect(throws: KeyEnvelopeError.requestMismatch) { try KeyExchangeSession().open(response) }
  }

  @Test("should refuse a response that names another request id but carries this session's ciphertext")
  func shouldBindRequestID() throws {
    let session = KeyExchangeSession()
    let other = KeyExchangeSession()
    let (response, _) = try KeyExchangeResponse.make(answering: other.request, vault: try Self.vault(), keys: Self.keys(1))
    let payload = try KeyExchangeCode.decode(response.encoded, kind: KeyExchangeCode.responseKind)
    let relabelled = KeyExchangeCode.encode(Array(payload.prefix(2)) + KeyExchangeCode.uuidBytes(session.request.id) + payload.dropFirst(18))
    #expect(throws: KeyEnvelopeError.authenticationFailed) { try session.open(try KeyExchangeResponse(encoded: relabelled)) }
  }

  @Test("should spend the session on a successful decryption")
  func shouldSpendOnSuccess() throws {
    let session = KeyExchangeSession()
    let (response, _) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1))
    _ = try session.open(response)
    #expect(throws: KeyEnvelopeError.sessionSpent) { try session.open(response) }
    let (another, _) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1))
    #expect(throws: KeyEnvelopeError.sessionSpent) { try session.open(another) }
  }

  @Test("should spend the session on a failed decryption or a bad plaintext, so the honest response is refused afterwards")
  func shouldSpendOnFailedDecryption() throws {
    let vault = try Self.vault()
    let session = KeyExchangeSession()
    let other = KeyExchangeSession()
    let (honest, _) = try KeyExchangeResponse.make(answering: session.request, vault: vault, keys: Self.keys(1))
    let (misdirected, _) = try KeyExchangeResponse.make(answering: other.request, vault: vault, keys: Self.keys(1))
    let payload = try KeyExchangeCode.decode(misdirected.encoded, kind: KeyExchangeCode.responseKind)
    let relabelled = KeyExchangeCode.encode(Array(payload.prefix(2)) + KeyExchangeCode.uuidBytes(session.request.id) + payload.dropFirst(18))
    #expect(throws: KeyEnvelopeError.authenticationFailed) { try session.open(try KeyExchangeResponse(encoded: relabelled)) }
    #expect(throws: KeyEnvelopeError.sessionSpent) { try session.open(honest) }

    let vaultChecked = KeyExchangeSession()
    let (wrongVault, _) = try KeyExchangeResponse.make(answering: vaultChecked.request, vault: try Self.vault("vault-two"), keys: Self.keys(1))
    #expect(throws: KeyEnvelopeError.vaultMismatch(expected: vault, found: try Self.vault("vault-two"))) { try vaultChecked.open(wrongVault, expecting: vault) }
    #expect(throws: KeyEnvelopeError.sessionSpent) { try vaultChecked.open(wrongVault) }
  }

  @Test("should not spend the session on text that never reaches decryption")
  func shouldNotSpendOnBadScan() throws {
    let session = KeyExchangeSession()
    let (honest, code) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1))
    var corrupted = Array(honest.encoded)
    corrupted[10] = corrupted[10] == "A" ? "B" : "A"
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeResponse(encoded: String(corrupted)) }
    #expect(throws: KeyEnvelopeError.unexpectedKind(1)) { try KeyExchangeResponse(encoded: session.request.encoded) }
    let (misdirected, _) = try KeyExchangeResponse.make(answering: KeyExchangeSession().request, vault: try Self.vault(), keys: Self.keys(1))
    #expect(throws: KeyEnvelopeError.requestMismatch) { try session.open(misdirected) }
    #expect(try session.open(try KeyExchangeResponse(encoded: honest.encoded)).confirmationCode == code)
  }

  @Test("should let exactly one of many concurrent opens decrypt")
  func shouldSpendOnceUnderConcurrency() throws {
    let session = KeyExchangeSession()
    let (response, _) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1))
    let outcomes = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 32) { _ in
      do {
        _ = try session.open(response)
        outcomes.withLock { $0.append("opened") }
      } catch {
        outcomes.withLock { $0.append((error as? KeyEnvelopeError)?.code ?? "unexpected") }
      }
    }
    let results = outcomes.withLock { $0 }
    #expect(results.filter { $0 == "opened" }.count == 1)
    #expect(results.filter { $0 == KeyEnvelopeError.sessionSpent.code }.count == 31)
  }

  @Test("should refuse a response for a vault other than the expected one")
  func shouldRefuseUnexpectedVault() throws {
    let session = KeyExchangeSession()
    let (response, _) = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault("vault-two"), keys: Self.keys(2))
    #expect(throws: KeyEnvelopeError.vaultMismatch(expected: try Self.vault(), found: try Self.vault("vault-two"))) {
      try session.open(response, expecting: try Self.vault())
    }
  }

  @Test("should reject every single-character substitution of an encoded request as corrupt text")
  func shouldRejectRequestSubstitutions() throws {
    let encoded = Array(KeyExchangeSession().request.encoded)
    for index in encoded.indices {
      for substitute in Self.substitutes where substitute != encoded[index] {
        var changed = encoded
        changed[index] = substitute
        #expect(throws: KeyEnvelopeError.corruptText, "position \(index) to \(substitute)") { try KeyExchangeRequest(encoded: String(changed)) }
      }
    }
  }

  @Test("should reject every single-character substitution of an encoded response as corrupt text or an authentication failure")
  func shouldRejectResponseSubstitutions() throws {
    let session = KeyExchangeSession()
    let encoded = Array(try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1)).response.encoded)
    for index in encoded.indices {
      for substitute in Self.substitutes where substitute != encoded[index] {
        var changed = encoded
        changed[index] = substitute
        do {
          _ = try session.open(try KeyExchangeResponse(encoded: String(changed)))
          Issue.record("position \(index) to \(substitute) was accepted")
        } catch {
          #expect(error == .corruptText || error == .authenticationFailed, "position \(index) to \(substitute): \(error)")
        }
      }
    }
  }

  @Test("should reject a response where a request is expected and the reverse")
  func shouldRejectWrongKind() throws {
    let session = KeyExchangeSession()
    let response = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(), keys: Self.keys(1)).response
    #expect(throws: KeyEnvelopeError.unexpectedKind(2)) { try KeyExchangeRequest(encoded: response.encoded) }
    #expect(throws: KeyEnvelopeError.unexpectedKind(1)) { try KeyExchangeResponse(encoded: session.request.encoded) }
  }

  @Test("should reject a payload with a valid checksum but an unknown version or wrong length")
  func shouldRejectBadPayloads() throws {
    let request = KeyExchangeSession().request
    let payload = try KeyExchangeCode.decode(request.encoded, kind: KeyExchangeCode.requestKind)
    #expect(throws: KeyEnvelopeError.unsupportedVersion(2)) { try KeyExchangeRequest(encoded: KeyExchangeCode.encode([2] + payload.dropFirst())) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeRequest(encoded: KeyExchangeCode.encode(payload + [0])) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeRequest(encoded: KeyExchangeCode.encode(Array(payload.dropLast()))) }
    #expect(throws: KeyEnvelopeError.malformed) { try KeyExchangeResponse(encoded: KeyExchangeCode.encode([1, 2] + Array(repeating: 0, count: 60))) }
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeRequest(encoded: "SLX1:") }
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeRequest(encoded: request.encoded.lowercased()) }
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeRequest(encoded: request.encoded + "=") }
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeRequest(encoded: " " + request.encoded) }
    #expect(throws: KeyEnvelopeError.corruptText) { try KeyExchangeRequest(encoded: "SLX1:" + String(repeating: "A", count: 4_000)) }
  }

  @Test("should not represent a request whose public key is not 32 bytes")
  func shouldValidateRequestKeyLength() {
    for count in [0, 31, 33] { #expect(KeyExchangeRequest(id: UUID(), publicKey: Data(count: count)) == nil) }
    #expect(KeyExchangeRequest(id: UUID(), publicKey: Data(count: 32)) != nil)
  }

  @Test("should refuse to answer a request that carries a low-order public key")
  func shouldRefuseLowOrderRequest() throws {
    let payload = [KeyExchangeCode.version, KeyExchangeCode.requestKind] + KeyExchangeCode.uuidBytes(UUID()) + Data(count: 32)
    let request = try KeyExchangeRequest(encoded: KeyExchangeCode.encode(Array(payload)))
    #expect(throws: KeyEnvelopeError.cryptoFailure) { try KeyExchangeResponse.make(answering: request, vault: try Self.vault(), keys: Self.keys(1)) }
  }

  @Test("should give a forged response for the same request a different confirmation code")
  func shouldExposeForgeryThroughCode() throws {
    let vault = try Self.vault()
    let session = KeyExchangeSession()
    let honest = try KeyExchangeResponse.make(answering: session.request, vault: vault, keys: Self.keys(2))
    let overheard = try Self.transmit(session.request)
    let forgedKeys = [VaultKey.generate(id: KeyID(UUID(uuid: (0, 0, 0, 0, 0, 0, 0x70, 0, 0x80, 0, 0, 0, 0, 0, 0, 0))))]
    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: overheard.publicKey)
    var plaintext = Data([UInt8(vault.rawValue.utf8.count)]) + Data(vault.rawValue.utf8) + Data([1])
    plaintext += forgedKeys[0].id.bytes + forgedKeys[0].rawBytes
    var sender = try HPKE.Sender(
      recipientKey: publicKey, ciphersuite: KeyExchangeCode.ciphersuite, info: KeyExchangeCode.info(requestID: overheard.id, publicKey: overheard.publicKey))
    let ciphertext = try sender.seal(plaintext, authenticating: KeyExchangeCode.associatedData(requestID: overheard.id))
    let forgedText = KeyExchangeCode.encode(
      [KeyExchangeCode.version, KeyExchangeCode.responseKind] + KeyExchangeCode.uuidBytes(overheard.id) + sender.encapsulatedKey + ciphertext)

    let forged = try session.open(try KeyExchangeResponse(encoded: forgedText), expecting: vault)
    #expect(forged.keys.map(\.id) == forgedKeys.map(\.id))
    #expect(forged.confirmationCode != honest.confirmationCode)
    #expect(throws: KeyEnvelopeError.sessionSpent) { try session.open(honest.response) }
  }

  @Test("should encode only QR alphanumeric characters and fit 16 keys in 1,500 characters")
  func shouldFitQRCode() throws {
    let session = KeyExchangeSession()
    let request = session.request.encoded
    let response = try KeyExchangeResponse.make(answering: session.request, vault: try Self.vault(String(repeating: "v", count: 64)), keys: Self.keys(16)).response.encoded
    for text in [request, response] {
      #expect(text.hasPrefix("SLX1:"))
      #expect(text.allSatisfy { Self.qrAlphanumeric.contains($0) })
    }
    #expect(request.count == 5 + 87)
    #expect(response.count <= 1_500)
  }

  @Test("should never print the session's private key")
  func shouldNotLeakSessionKey() {
    let session = KeyExchangeSession()
    #expect(Mirror(reflecting: session).children.map(\.label) == ["request"])
    #expect(!String(describing: session).contains("PrivateKey"))
  }

  @Test("should never trap on random text")
  func shouldSurviveRandomText() throws {
    let session = KeyExchangeSession()
    try forAll(iterations: 300) { generator in
      let body = Base32.encode(Array(generator.data(count: generator.int(in: 0...120))))
      let text = generator.chance(0.5) ? "SLX1:" + body : generator.unicodeString(maxLength: 80)
      _ = try? KeyExchangeRequest(encoded: text)
      if let response = try? KeyExchangeResponse(encoded: text) { _ = try? session.open(response) }
    }
  }
}
