import Foundation
import ShadowCore
import ShadowStore
import Testing

@Suite("EntityKind")
struct EntityKindTests {
  @Test("should accept lower-case letters, digits and underscores up to 64 characters", arguments: ["a", "bible_page", "v2", String(repeating: "z", count: 64)])
  func shouldAcceptValidKinds(_ text: String) {
    #expect(EntityKind(text)?.rawValue == text)
  }

  @Test("should reject empty, long or out-of-alphabet kinds", arguments: ["", String(repeating: "z", count: 65), "Note", "bible-page", "a b", "n:x", "\u{E9}"])
  func shouldRejectInvalidKinds(_ text: String) {
    #expect(EntityKind(text) == nil)
  }

  @Test("should order by UTF-8 bytes and round-trip through Codable")
  func shouldOrderAndCode() throws {
    let first = try #require(EntityKind("a_b"))
    let second = try #require(EntityKind("ab"))
    #expect(first < second)
    let data = try JSONEncoder().encode(first)
    #expect(String(decoding: data, as: UTF8.self) == "\"a_b\"")
    #expect(try JSONDecoder().decode(EntityKind.self, from: data) == first)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(EntityKind.self, from: Data("\"A\"".utf8)) }
  }
}

@Suite("EntityKey")
struct EntityKeyTests {
  @Test("should accept the key alphabet up to 128 characters", arguments: ["k", "n:0d4c", "a-b_c:d", String(repeating: "9", count: 128)])
  func shouldAcceptValidKeys(_ text: String) {
    #expect(EntityKey(text)?.rawValue == text)
  }

  @Test("should reject empty, long or out-of-alphabet keys", arguments: ["", String(repeating: "9", count: 129), "K", "a.b", "a/b", " ", "\u{E9}"])
  func shouldRejectInvalidKeys(_ text: String) {
    #expect(EntityKey(text) == nil)
  }

  @Test("should write a UUID as lower-case text")
  func shouldWriteUUIDLowerCase() throws {
    let uuid = try #require(UUID(uuidString: "0193A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B"))
    #expect(EntityKey(uuid: uuid).rawValue == "0193a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
    #expect(EntityKey(EntityKey(uuid: uuid).rawValue) == EntityKey(uuid: uuid))
  }

  @Test("should derive a stable natural key from scope, kind and components")
  func shouldDeriveStableNaturalKey() {
    let key = EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["chapter", "3"])
    #expect(key.rawValue == "n:94ba733f0f4724cb38f4d13edd4b1a8e2f2c5b94")
    #expect(key.rawValue.utf8.count == 42)
    #expect(EntityKey(key.rawValue) == key)
  }

  @Test("should change the natural key when any input changes")
  func shouldBeSensitiveToEachInput() {
    let base = EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["chapter", "3"])
    #expect(EntityKey.natural(scope: "novel-2", kind: Fixture.note, components: ["chapter", "3"]) != base)
    #expect(EntityKey.natural(scope: "novel-1", kind: Fixture.draft, components: ["chapter", "3"]) != base)
    #expect(EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["chapter", "4"]) != base)
    #expect(EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["chapters", "3"]) != base)
    #expect(EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["chapter", "3", ""]) != base)
    #expect(EntityKey.natural(scope: "novel-1", kind: Fixture.note, components: ["3", "chapter"]) != base)
  }

  @Test("should not collide when component boundaries move")
  func shouldNotCollideAcrossBoundaries() {
    let left = EntityKey.natural(scope: "s", kind: Fixture.note, components: ["ab", "c"])
    let right = EntityKey.natural(scope: "s", kind: Fixture.note, components: ["a", "bc"])
    let joined = EntityKey.natural(scope: "s", kind: Fixture.note, components: ["abc"])
    #expect(Set([left, right, joined]).count == 3)
  }

  @Test("should keep normalisation variants of a component distinct")
  func shouldKeepNormalisationVariantsDistinct() {
    let composed = EntityKey.natural(scope: "s", kind: Fixture.note, components: ["\u{E9}"])
    let decomposed = EntityKey.natural(scope: "s", kind: Fixture.note, components: ["e\u{301}"])
    #expect(composed != decomposed)
  }
}

@Suite("EntityRef")
struct EntityRefTests {
  @Test("should order by kind, then key")
  func shouldOrderByKindThenKey() {
    let refs = [
      EntityRef(kind: Fixture.note, key: Fixture.key("a")), EntityRef(kind: Fixture.draft, key: Fixture.key("z")), EntityRef(kind: Fixture.note, key: Fixture.key("-")),
    ]
    #expect(refs.sorted().map { "\($0.kind):\($0.key)" } == ["draft:z", "note:-", "note:a"])
  }
}
