import Foundation
import Testing

@testable import ShadowSync

@Suite("VaultID")
struct VaultIDTests {
  @Test("should accept 1...64 bytes of lower-case letters, digits and hyphens")
  func shouldAcceptValidIDs() {
    for raw in ["a", "vault-1", "0", "-", String(repeating: "z", count: 64)] {
      #expect(VaultID(raw)?.rawValue == raw)
    }
  }

  @Test("should reject empty, long or out-of-alphabet ids")
  func shouldRejectInvalidIDs() {
    for raw in ["", String(repeating: "a", count: 65), "Vault", "va ult", "vault_1", "vault/1", "väult", "vault\u{0}"] {
      #expect(VaultID(raw) == nil)
    }
  }

  @Test("should encode as a bare string and reject invalid ids when decoding")
  func shouldCodeAsString() throws {
    let vault = try #require(VaultID("vault-1"))
    let encoded = try JSONEncoder().encode([vault])
    #expect(String(decoding: encoded, as: UTF8.self) == "[\"vault-1\"]")
    #expect(try JSONDecoder().decode([VaultID].self, from: encoded) == [vault])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([VaultID].self, from: Data("[\"Vault\"]".utf8)) }
    #expect(vault.description == "vault-1")
  }
}

@Suite("KeyID")
struct KeyIDTests {
  @Test("should describe itself as lower-case UUID text and parse only that form")
  func shouldUseLowerCaseText() throws {
    let uuid = try #require(UUID(uuidString: "0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9"))
    let keyID = KeyID(uuid)
    #expect(keyID.description == "0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9")
    #expect(KeyID("0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9") == keyID)
    #expect(KeyID("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9") == nil)
    #expect(KeyID("not-a-uuid") == nil)
    #expect(keyID.bytes == [0x0A, 0x1B, 0x2C, 0x3D, 0x4E, 0x5F, 0x60, 0x71, 0x82, 0x93, 0xA4, 0xB5, 0xC6, 0xD7, 0xE8, 0xF9])
    #expect(KeyID(bytes: keyID.bytes) == keyID)
  }

  @Test("should order by text")
  func shouldOrderByText() throws {
    let low = try #require(KeyID("0fffffff-ffff-ffff-ffff-ffffffffffff"))
    let high = try #require(KeyID("a0000000-0000-0000-0000-000000000000"))
    #expect(low < high)
    #expect([high, low].sorted() == [low, high])
  }

  @Test("should encode as a bare string and reject invalid ids when decoding")
  func shouldCodeAsString() throws {
    let keyID = KeyID(UUID())
    let encoded = try JSONEncoder().encode([keyID])
    #expect(String(decoding: encoded, as: UTF8.self) == "[\"\(keyID.description)\"]")
    #expect(try JSONDecoder().decode([KeyID].self, from: encoded) == [keyID])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode([KeyID].self, from: Data("[\"nope\"]".utf8)) }
  }
}

@Suite("VaultKey")
struct VaultKeyTests {
  @Test("should accept exactly 32 raw bytes")
  func shouldRequireThirtyTwoBytes() {
    let id = KeyID(UUID())
    #expect(VaultKey(id: id, rawBytes: Data(count: 31)) == nil)
    #expect(VaultKey(id: id, rawBytes: Data(count: 33)) == nil)
    #expect(VaultKey(id: id, rawBytes: Data(0..<32))?.rawBytes == Data(0..<32))
  }

  @Test("should generate distinct 32-byte keys")
  func shouldGenerateKeys() {
    let id = KeyID(UUID())
    let first = VaultKey.generate(id: id)
    let second = VaultKey.generate(id: id)
    #expect(first.id == id)
    #expect(first.rawBytes.count == 32)
    #expect(first.rawBytes != second.rawBytes)
  }

  @Test("should not reveal key bytes when described")
  func shouldNotLeakKeyBytes() throws {
    let id = try #require(KeyID("00000000-0000-4000-8000-000000000000"))
    let key = try #require(VaultKey(id: id, rawBytes: Data(repeating: 0xAB, count: 32)))
    for text in [String(describing: key), String(reflecting: key), "\(key)"] {
      #expect(text.contains(id.description))
      #expect(!text.lowercased().contains("abab"))
      #expect(!text.contains("171"))
      #expect(!text.contains("q6ur"))
    }
    #expect(Mirror(reflecting: key).children.map(\.label) == ["id"])
  }
}

@Suite("BlobName")
struct BlobNameTests {
  @Test("should be 64 lower-case hex characters and deterministic per key")
  func shouldBeDeterministic() throws {
    let key = try VaultFileFixtures.key(byte: 0x01)
    let name = BlobName.make(for: Data("blob".utf8), key: key)
    #expect(name.count == 64)
    #expect(name.allSatisfy { "0123456789abcdef".contains($0) })
    #expect(BlobName.make(for: Data("blob".utf8), key: key) == name)
    #expect(BlobName.make(for: Data("blob".utf8), key: try VaultFileFixtures.key(id: KeyID(UUID()), byte: 0x01)) == name)
  }

  @Test("should differ across keys and content")
  func shouldDifferAcrossKeys() throws {
    let content = Data("blob".utf8)
    let first = BlobName.make(for: content, key: try VaultFileFixtures.key(byte: 0x01))
    #expect(BlobName.make(for: content, key: try VaultFileFixtures.key(byte: 0x02)) != first)
    #expect(BlobName.make(for: Data("blob!".utf8), key: try VaultFileFixtures.key(byte: 0x01)) != first)
    #expect(first != ContentHash.hex(of: content, length: 64))
  }
}

@Suite("ContentHash")
struct ContentHashTests {
  private static let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  @Test("should return the leading lower-case hex of SHA-256")
  func shouldReturnPrefix() {
    #expect(ContentHash.hex(of: Data("abc".utf8)) == String(Self.abcDigest.prefix(16)))
    #expect(ContentHash.hex(of: Data("abc".utf8), length: 64) == Self.abcDigest)
    #expect(ContentHash.hex(of: Data("abc".utf8), length: 5) == "ba781")
  }

  @Test("should clamp the length to 0...64")
  func shouldClampLength() {
    #expect(ContentHash.hex(of: Data("abc".utf8), length: 0) == "")
    #expect(ContentHash.hex(of: Data("abc".utf8), length: -3) == "")
    #expect(ContentHash.hex(of: Data("abc".utf8), length: 100) == Self.abcDigest)
  }
}
