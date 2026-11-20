import Foundation
import ShadowSync
import ShadowTestSupport
import Testing

@testable import ShadowSyncOneDrive

@Suite("OneDriveName", TestTimeLimit.quick)
struct OneDriveNameTests {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/")

  private static func randomKey(_ generator: inout SeededGenerator) -> ObjectKey? {
    let length = Int.random(in: 1...260, using: &generator)
    return ObjectKey(String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }))
  }

  @Test("should spell vault keys unchanged apart from the separator")
  func spellsVaultKeys() throws {
    #expect(OneDriveName.encode(try key("vault.json")) == "vault.json")
    #expect(
      OneDriveName.encode(try key("replicas/0192e4c1-7a2b-7c3d-8e4f-5a6b7c8d9e0f/seg/000000000001-000000000002-ab"))
        == "replicas!0192e4c1-7a2b-7c3d-8e4f-5a6b7c8d9e0f!seg!000000000001-000000000002-ab")
  }

  @Test("should escape capitals, underscores and trailing dots")
  func escapes() throws {
    #expect(OneDriveName.encode(try key("Ab_c")) == "~ab~1c")
    #expect(OneDriveName.encode(try key("a.b.")) == "a.b~0")
    #expect(OneDriveName.encode(try key("...")) == "~0~0~0")
    #expect(OneDriveName.encode(try key("a./b")) == "a.!b")
    #expect(OneDriveName.encode(try key("x/_vti_")) == "x!~1vti~1")
  }

  @Test("should prefix names OneDrive reserves")
  func prefixesReservedNames() throws {
    for raw in ["con", "nul.txt", "com1", "lpt9.a.b", "desktop.ini", ".lock"] {
      let name = OneDriveName.encode(try key(raw))
      #expect(name == "~2" + raw)
      #expect(OneDriveName.decode(name) == .key(try key(raw)))
      #expect(OneDriveName.decode(raw) == nil)
    }
    #expect(OneDriveName.encode(try key("console")) == "console")
    #expect(OneDriveName.encode(try key("CON")) == "~c~o~n")
  }

  @Test("should round trip every key and give keys that differ only by case names that differ without case")
  func roundTripsAndSeparatesCase() throws {
    var generator = SeededGenerator(seed: 0x0D21)
    var folded: [String: ObjectKey] = [:]
    for _ in 0..<4000 {
      guard let key = Self.randomKey(&generator) else { continue }
      let name = OneDriveName.encode(key)
      #expect(OneDriveName.decode(name) == (name.hasPrefix("~3") ? .overflow(name) : .key(key)))
      #expect(name.utf8.count <= OneDriveName.maximumLength)
      #expect(name.allSatisfy { $0.isLowercase || $0.isNumber || ".-!~".contains($0) })
      #expect(!name.hasSuffix("."))
      if let other = folded.updateValue(key, forKey: name.lowercased()) { #expect(other == key) }
      let swapped = String(key.rawValue.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
      if let twin = ObjectKey(swapped), twin != key { #expect(OneDriveName.encode(twin).lowercased() != name.lowercased()) }
    }
  }

  @Test("should decode only the canonical spelling of a key")
  func rejectsNonCanonicalNames() {
    for name in ["A", "a~0b", "a.", "a_b", "~2abc", "~", "~A", "a~9", "a!!b", "!a", "a b", "a/b", "~3abc", "~3" + String(repeating: "g", count: 64)] {
      #expect(OneDriveName.decode(name) == nil, "\(name)")
    }
  }

  @Test("should store a key too long for a OneDrive name under a digest and read its key back from the header")
  func overflowsLongKeys() throws {
    let long = try key(String(repeating: "k", count: 100) + "/" + String(repeating: "Q", count: 100))
    let name = OneDriveName.encode(long)
    #expect(name.hasPrefix("~3"))
    #expect(name.utf8.count == 66)
    #expect(OneDriveName.decode(name) == .overflow(name))
    let header = OneDriveKeyHeader.encode(long)
    let decoded = try #require(OneDriveKeyHeader.decode(header + Data([1, 2, 3]), name: name))
    #expect(decoded.key == long)
    #expect(decoded.length == header.count)
    #expect(OneDriveKeyHeader.decode(header, name: OneDriveName.overflowName(try key("other"))) == nil)
    #expect(OneDriveKeyHeader.decode(Data("not a header".utf8), name: name) == nil)
    #expect(OneDriveName.encode(try key(String(repeating: "k", count: OneDriveName.maximumLength))) == String(repeating: "k", count: OneDriveName.maximumLength))
    #expect(OneDriveName.encode(try key(String(repeating: "K", count: 91))).hasPrefix("~3"))
  }
}
