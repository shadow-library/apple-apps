import Foundation
import NovelForgeCore
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@Suite("NovelForgeKey")
struct NovelForgeKeyTests {
  private static let novel = SchemaFixture.novel

  private static func textKeyed(_ text: String) -> [EntityRef] {
    [
      NovelForgeKey.volume(novel: novel, key: text), NovelForgeKey.milestone(novel: novel, key: text), NovelForgeKey.thread(novel: novel, key: text),
      NovelForgeKey.mystery(novel: novel, key: text), NovelForgeKey.secret(novel: novel, key: text), NovelForgeKey.entity(novel: novel, key: text),
      NovelForgeKey.characterKnowledge(novel: novel, fact: text, entity: text), NovelForgeKey.page(novel: novel, section: .lore, slug: text),
    ]
  }

  @Test func shouldBuildTheSameKeyOnBothDevicesForTheSameComponents() async throws {
    let devices = try Devices()
    let ref = NovelForgeKey.volume(novel: Self.novel, key: "book-one")
    try await SchemaFixture.set(ref, ["natural_key": try NovelForgeKey(novel: Self.novel, .volume("book-one")).stored, "title": "One"], in: devices.first)
    devices.clock.advance()
    let rebuilt = NovelForgeKey.volume(novel: Self.novel, key: "book-one")
    try await SchemaFixture.set(rebuilt, ["natural_key": try NovelForgeKey(novel: Self.novel, .volume("book-one")).stored, "objective": "Win"], in: devices.second)
    try await devices.exchange()
    #expect(ref == rebuilt)
    for store in devices.both { #expect(try await SchemaFixture.count(.volume, in: store) == 1) }
  }

  @Test func shouldGiveThePrecomposedAndDecomposedSpellingsOneKey() throws {
    let precomposed = "Am\u{E9}lie"
    let decomposed = "Ame\u{301}lie"
    #expect(!precomposed.utf8.elementsEqual(decomposed.utf8))
    #expect(Self.textKeyed(precomposed) == Self.textKeyed(decomposed))
    let stored = try NovelForgeKey(novel: Self.novel, .entity(decomposed)).stored
    #expect(stored["entity"]?.stringValue.map { Array($0.utf8) } == Array(precomposed.utf8))
  }

  @Test func shouldNormaliseCanonicallyButNotByCompatibility() {
    #expect(Self.textKeyed("\u{FB01}re") != Self.textKeyed("fire"))
  }

  @Test func shouldKeepLetterCaseAsTheReferenceUniqueIndexesDo() {
    #expect(zip(Self.textKeyed("Aria"), Self.textKeyed("aria")).allSatisfy { $0 != $1 })
  }

  @Test func shouldKeepSurroundingWhitespaceAsTheReferenceStoresKeysUntrimmed() {
    #expect(zip(Self.textKeyed(" aria"), Self.textKeyed("aria")).allSatisfy { $0 != $1 })
    #expect(zip(Self.textKeyed("aria "), Self.textKeyed("aria")).allSatisfy { $0 != $1 })
  }

  @Test func shouldRefuseChapterNumbersBelowOne() {
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(0)) { try NovelForgeKey.draft(novel: Self.novel, chapter: 0) }
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(-1)) { try NovelForgeKey.finalChapter(novel: Self.novel, chapter: -1) }
    #expect(throws: NovelForgeKeyError.chapterOutOfRange(0)) { try NovelForgeKey(novel: Self.novel, .chapterPlan(chapter: 0)) }
  }

  @Test func shouldNeverCollideAcrossNovelsOrKinds() throws {
    let keys = try SchemaFixture.naturalKeys(novel: SchemaFixture.novel) + SchemaFixture.naturalKeys(novel: SchemaFixture.otherNovel)
    #expect(Set(keys.map(\.ref)).count == keys.count)
    #expect(Set(keys.map(\.ref.key)).count == keys.count)
    #expect(Set(try SchemaFixture.naturalKeys(novel: SchemaFixture.novel).map(\.kind)).count == keys.count / 2)
  }

  @Test func shouldReadTheComponentsBackFromTheStoredField() async throws {
    let store = try SchemaFixture.store()
    for key in try SchemaFixture.naturalKeys(novel: Self.novel, text: "Ame\u{301}lie") {
      try await SchemaFixture.set(key.ref, ["natural_key": key.stored], in: store)
      let state = try #require(try await SchemaFixture.state(key.ref, in: store))
      #expect(try NovelForgeKey(reading: state, of: key.ref) == key)
    }
  }

  @Test func shouldRoundTripRandomComponentsThroughTheStoredField() throws {
    try forAll(iterations: 100) { generator in
      let text = generator.unicodeString(maxLength: 12)
      let components: [NovelForgeKey.Components] = [
        .characterKnowledge(fact: text, entity: generator.unicodeString(maxLength: 6)),
        .page(section: .known(generator.pick(from: BiblePageSection.allCases)), slug: text), .page(section: .unknown(generator.asciiString(maxLength: 8)), slug: text),
        .finalChapter(chapter: generator.int(in: 1...500)),
      ]
      for component in components {
        let key = try NovelForgeKey(novel: SchemaFixture.novel, component)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: CanonicalJSON.encode(key.stored))
        #expect(try NovelForgeKey(stored: decoded, of: key.ref) == key)
      }
    }
  }

  @Test func shouldReadAPageSectionANewerVersionAddedWithoutAnError() async throws {
    let store = try SchemaFixture.store()
    let key = try NovelForgeKey(novel: Self.novel, .page(section: .unknown("timeline"), slug: "eras"))
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored], in: store)
    let state = try #require(try await SchemaFixture.state(key.ref, in: store))
    let read = try NovelForgeKey(reading: state, of: key.ref)
    #expect(read.components == .page(section: .unknown("timeline"), slug: "eras"))
    #expect(read.ref == key.ref)
    #expect(try NovelForgeKey(novel: Self.novel, .page(section: .unknown("world"), slug: "eras")).ref == NovelForgeKey.page(novel: Self.novel, section: .world, slug: "eras"))
  }

  @Test func shouldRefuseAStoredKeyThatHashesToAnotherEntity() throws {
    let ref = NovelForgeKey.entity(novel: Self.novel, key: "aria")
    let stored = try NovelForgeKey(novel: Self.novel, .entity("bran")).stored
    #expect(throws: NovelForgeKeyError.keyMismatch(ref)) { try NovelForgeKey(stored: stored, of: ref) }
    let otherNovel = try NovelForgeKey(novel: SchemaFixture.otherNovel, .entity("aria")).stored
    #expect(throws: NovelForgeKeyError.keyMismatch(ref)) { try NovelForgeKey(stored: otherNovel, of: ref) }
  }

  @Test func shouldRefuseAMalformedStoredKey() {
    let ref = NovelForgeKey.entity(novel: Self.novel, key: "aria")
    let novel = JSONValue.string(Self.novel.uuidString.lowercased())
    let malformed: [JSONValue] = [
      "aria", ["novel": novel], ["novel": novel, "entity": "aria", "extra": 1], ["novel": novel, "entity": 7], ["novel": "NOT-A-UUID", "entity": "aria"],
    ]
    for value in malformed {
      #expect(throws: NovelForgeKeyError.self) { try NovelForgeKey(stored: value, of: ref) }
    }
  }

  @Test func shouldRefuseReadingAKindWithRandomKeys() {
    let ref = NovelForgeKey.approval(UUID())
    #expect(throws: NovelForgeKeyError.notNaturallyKeyed("nf_approval")) { try NovelForgeKey(stored: [:], of: ref) }
  }
}
