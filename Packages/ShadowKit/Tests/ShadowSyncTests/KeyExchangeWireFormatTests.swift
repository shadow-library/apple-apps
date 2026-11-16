import CryptoKit
import Foundation
import Testing

@testable import ShadowSync

enum WireLiterals {
  static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
  static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

  static func hex(_ text: String) throws -> [UInt8] {
    let digits = Array(text)
    try #require(digits.count.isMultiple(of: 2))
    return try stride(from: 0, to: digits.count, by: 2).map { try #require(UInt8(String(digits[$0...($0 + 1)]), radix: 16)) }
  }

  static func base32(_ bytes: [UInt8]) -> String {
    var bits = bytes.map { byte in
      let binary = String(byte, radix: 2)
      return String(repeating: "0", count: 8 - binary.count) + binary
    }.joined()
    while !bits.count.isMultiple(of: 5) { bits += "0" }
    let characters = Array(bits)
    return String(stride(from: 0, to: characters.count, by: 5).map { alphabet[Int(String(characters[$0..<($0 + 5)]), radix: 2) ?? 0] })
  }

  static func base32Decode(_ text: String) throws -> [UInt8] {
    let bits = try text.map { character in
      let index = try #require(alphabet.firstIndex(of: character))
      let binary = String(index, radix: 2)
      return String(repeating: "0", count: 5 - binary.count) + binary
    }.joined()
    let characters = Array(bits)
    return try stride(from: 0, to: characters.count / 8 * 8, by: 8).map { try #require(UInt8(String(characters[$0..<($0 + 8)]), radix: 2)) }
  }

  static func checksum(_ payload: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: payload).prefix(4))
  }

  static func code(_ secret: SymmetricKey) -> String {
    let bytes = secret.withUnsafeBytes { Array($0) }
    let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    return String(format: "%06u", value % 1_000_000)
  }

  static func payload(of text: String) throws -> [UInt8] {
    try #require(text.hasPrefix("SLX1:"))
    let bytes = try base32Decode(String(text.dropFirst(5)))
    try #require(bytes.count > 4)
    let payload = Array(bytes.dropLast(4))
    #expect(Array(bytes.suffix(4)) == checksum(payload))
    return payload
  }
}

@Suite("KeyExchange wire format")
struct KeyExchangeWireFormatTests {
  private static let requestText = "SLX1:AEAQDE5BWLB5I7S7RJVXZDM6B4NCWCMDXO4XC7QCTPWQQU2UESNY6EPYY4WTJ5J3BB4PEOQ6ZCEBDTT2GMIIATY"
  private static let requestID = "0193a1b2c3d47e5f8a6b7c8d9e0f1a2b"
  private static let requestPublicKey = "0983bbb9717e029bed085354249b8f11f8c72d34f53b0878f23a1ec88811ce7a"
  private static let firstKeyID = "0193a1b2c3d47e5f8a6b000000000001"
  private static let firstKey = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  private static let secondKeyID = "0193a1b2c3d47e5f8a6b000000000002"
  private static let secondKey = "a0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"

  private static func plaintext() throws -> [UInt8] {
    let vault = Array("vault-one".utf8)
    let firstEntry = try WireLiterals.hex(firstKeyID) + WireLiterals.hex(firstKey)
    let secondEntry = try WireLiterals.hex(secondKeyID) + WireLiterals.hex(secondKey)
    return [0x09] + vault + [0x02] + firstEntry + secondEntry
  }

  private static func info(requestID: [UInt8], publicKey: [UInt8]) -> Data {
    Data("SLV1/key-exchange".utf8) + Data([0x00]) + Data(requestID) + Data(publicKey)
  }

  @Test("should decode a fixed request string to its id and public key, and re-encode it identically")
  func shouldDecodeFixedRequest() throws {
    let request = try KeyExchangeRequest(encoded: Self.requestText)
    #expect(request.id == UUID(uuidString: "0193A1B2-C3D4-7E5F-8A6B-7C8D9E0F1A2B"))
    #expect(Array(request.publicKey) == (try WireLiterals.hex(Self.requestPublicKey)))
    #expect(request.encoded == Self.requestText)
    let literalPayload = try [0x01, 0x01] + WireLiterals.hex(Self.requestID) + WireLiterals.hex(Self.requestPublicKey)
    #expect("SLX1:" + WireLiterals.base32(literalPayload + WireLiterals.checksum(literalPayload)) == Self.requestText)
  }

  @Test("should open a response built by hand from literals and plain CryptoKit")
  func shouldOpenHandBuiltResponse() throws {
    let session = KeyExchangeSession()
    let requestPayload = try WireLiterals.payload(of: session.request.encoded)
    try #require(requestPayload.count == 50)
    #expect(Array(requestPayload.prefix(2)) == [0x01, 0x01])
    let requestID = Array(requestPayload[2..<18])
    let publicKeyBytes = Array(requestPayload[18..<50])

    let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyBytes)
    var sender = try HPKE.Sender(recipientKey: publicKey, ciphersuite: WireLiterals.suite, info: Self.info(requestID: requestID, publicKey: publicKeyBytes))
    let associatedData = [0x01, 0x02] + requestID
    let ciphertext = try sender.seal(try Self.plaintext(), authenticating: associatedData)
    let payload = associatedData + Array(sender.encapsulatedKey) + Array(ciphertext)
    let text = "SLX1:" + WireLiterals.base32(payload + WireLiterals.checksum(payload))
    let expectedCode = WireLiterals.code(try sender.exportSecret(context: Data("SLV1/key-exchange/confirm".utf8), outputByteCount: 4))

    let response = try KeyExchangeResponse(encoded: text)
    #expect(response.encoded == text)
    let vault = try #require(VaultID("vault-one"))
    let result = try session.open(response, expecting: vault)
    #expect(result.vault.rawValue == "vault-one")
    #expect(result.keys.map(\.id.description) == ["0193a1b2-c3d4-7e5f-8a6b-000000000001", "0193a1b2-c3d4-7e5f-8a6b-000000000002"])
    #expect(result.keys.map { Array($0.rawBytes) } == [try WireLiterals.hex(Self.firstKey), try WireLiterals.hex(Self.secondKey)])
    #expect(result.confirmationCode == expectedCode)
  }

  @Test("should make a response that a hand-written HPKE recipient opens with the same literals")
  func shouldMakeResponseThatOpensByHand() throws {
    let privateKey = Curve25519.KeyAgreement.PrivateKey()
    let requestID = try WireLiterals.hex(Self.requestID)
    let publicKeyBytes = Array(privateKey.publicKey.rawRepresentation)
    let requestPayload = [0x01, 0x01] + requestID + publicKeyBytes
    let request = try KeyExchangeRequest(encoded: "SLX1:" + WireLiterals.base32(requestPayload + WireLiterals.checksum(requestPayload)))
    let firstID = try #require(KeyID("0193a1b2-c3d4-7e5f-8a6b-000000000001"))
    let secondID = try #require(KeyID("0193a1b2-c3d4-7e5f-8a6b-000000000002"))
    let keys = [
      try #require(VaultKey(id: firstID, rawBytes: Data(try WireLiterals.hex(Self.firstKey)))),
      try #require(VaultKey(id: secondID, rawBytes: Data(try WireLiterals.hex(Self.secondKey)))),
    ]
    let (response, code) = try KeyExchangeResponse.make(answering: request, vault: try #require(VaultID("vault-one")), keys: keys)

    let payload = try WireLiterals.payload(of: response.encoded)
    try #require(payload.count > 50)
    #expect(Array(payload.prefix(2)) == [0x01, 0x02])
    #expect(Array(payload[2..<18]) == requestID)
    var recipient = try HPKE.Recipient(
      privateKey: privateKey, ciphersuite: WireLiterals.suite, info: Self.info(requestID: requestID, publicKey: publicKeyBytes),
      encapsulatedKey: Data(payload[18..<50]))
    let opened = try recipient.open(Data(payload[50...]), authenticating: Data(payload[0..<18]))
    #expect(Array(opened) == (try Self.plaintext()))
    #expect(code == WireLiterals.code(try recipient.exportSecret(context: Data("SLV1/key-exchange/confirm".utf8), outputByteCount: 4)))
  }

  @Test("should reject a hand-built response whose associated data or info differs from the specification")
  func shouldRejectOffSpecResponses() throws {
    for variant in 0..<3 {
      let session = KeyExchangeSession()
      let requestPayload = try WireLiterals.payload(of: session.request.encoded)
      let requestID = Array(requestPayload[2..<18])
      let publicKeyBytes = Array(requestPayload[18..<50])
      let info = variant == 0 ? Data("SLV1/key-exchange".utf8) + Data(requestID) + Data(publicKeyBytes) : Self.info(requestID: requestID, publicKey: publicKeyBytes)
      var sender = try HPKE.Sender(
        recipientKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKeyBytes), ciphersuite: WireLiterals.suite, info: info)
      let header = [0x01, 0x02] + requestID
      let associatedData = variant == 1 ? header + Array(sender.encapsulatedKey) : variant == 2 ? Array(header.prefix(17)) : header
      let ciphertext = try sender.seal(try Self.plaintext(), authenticating: associatedData)
      let payload = header + Array(sender.encapsulatedKey) + Array(ciphertext)
      let response = try KeyExchangeResponse(encoded: "SLX1:" + WireLiterals.base32(payload + WireLiterals.checksum(payload)))
      #expect(throws: KeyEnvelopeError.authenticationFailed, "variant \(variant)") { try session.open(response) }
    }
  }
}
