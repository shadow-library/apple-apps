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
        .finalChapter(chapter: generator.int(in: 1...500)), .proposalChange(proposal: UUID(), index: generator.int(in: 0...10_000)),
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

  @Test(arguments: [
    NovelForgeKey.approval(UUID()), NovelForgeKey.chatSession(UUID()), NovelForgeKey.chatMessage(UUID()), NovelForgeKey.chatSummary(UUID()), NovelForgeKey.proposal(UUID()),
  ])
  func shouldRefuseReadingAKindWithRandomKeys(_ ref: EntityRef) {
    #expect(throws: NovelForgeKeyError.notNaturallyKeyed(ref.kind.rawValue)) { try NovelForgeKey(stored: [:], of: ref) }
  }

  @Test func shouldHashAProposalChangeFromTheLowerCaseProposalThenTheDecimalIndex() throws {
    let key = try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: SchemaFixture.proposal, index: 3)
    let expected = EntityKey.natural(
      scope: "6f0c4d1e-0000-4000-8000-000000000001", kind: NovelForgeKind.proposalChange.entityKind, components: ["6f0c4d1e-0000-4000-8000-0000000000a1", "3"])
    #expect(key.ref == EntityRef(kind: NovelForgeKind.proposalChange.entityKind, key: expected))
    #expect(key.stored == ["novel": "6f0c4d1e-0000-4000-8000-000000000001", "proposal": "6f0c4d1e-0000-4000-8000-0000000000a1", "index": 3])
  }

  @Test func shouldKeepEveryNaturalKeyAsFrozen() throws {
    let frozen: [NovelForgeKind: String] = [
      .volume: "n:d262d2b9089e1a6d3d412972b0cec0e757906def", .milestone: "n:9932b9250184e8c12a43c0807992de93ba701ff4",
      .thread: "n:d077f210035cb90d0470e48e5da6571326563a03", .mystery: "n:9695a80ec482a1ef074b50c813442344b1e9a7c7",
      .secret: "n:5ece3e8c8ded468f9981f39f44ec5f3ee852afec", .entity: "n:2c459ee19c444e54e2df572dfaacf8bd2baa28a1",
      .characterKnowledge: "n:ca7c6f16259f05a686743e33f908a32c365acba3", .page: "n:e9f22938281a023e4cde8274206e9520f4b214a4",
      .chapterPlan: "n:d9776391406114475540f661b90be54986e72be6", .draft: "n:c375a907d001ad7fab5eecaa973cf1a68b56cbcb",
      .finalChapter: "n:26792fb64b234503b40b705131127714d6a095d0", .authorNotes: "n:424386a6c8407d0bf63d2396ba6765798ae94e5b",
      .proposalChange: "n:f94891d877a63823a3aa6800423f2be0cc35c176",
    ]
    let keys = try SchemaFixture.naturalKeys(novel: Self.novel)
    #expect(Set(keys.map(\.kind)) == Set(frozen.keys))
    for key in keys { #expect(key.ref.key.rawValue == frozen[key.kind], "\(key.kind) hashes differently") }
    let indexes = [0: "n:073fabbb88312779a12ae8f4278fcf152aac017f", 1: "n:9f51c2ce4dd9f226ec5cf3940ea6f0d61e9d9360", 10: "n:f74d185aa83f46a9cc0ec31070f7c24cbf7b4411"]
    for (index, key) in indexes {
      #expect(try NovelForgeKey.proposalChange(novel: Self.novel, proposal: SchemaFixture.proposal, index: index).key.rawValue == key)
    }
  }

  @Test func shouldGiveEveryProposalIndexAndNovelItsOwnChange() throws {
    let other = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000a2")
    let refs = try [
      (Self.novel, SchemaFixture.proposal, 0), (Self.novel, SchemaFixture.proposal, 1), (Self.novel, SchemaFixture.proposal, 10), (Self.novel, other, 1),
      (SchemaFixture.otherNovel, SchemaFixture.proposal, 1),
    ]
    .map { novel, proposal, index throws(NovelForgeKeyError) in try NovelForgeKey.proposalChange(novel: novel, proposal: proposal, index: index) }
    #expect(Set(refs).count == refs.count)
  }

  @Test func shouldRefuseANegativeOperationIndexAndAcceptIndexZero() throws {
    #expect(throws: NovelForgeKeyError.opIndexOutOfRange(-1)) { try NovelForgeKey.proposalChange(novel: Self.novel, proposal: SchemaFixture.proposal, index: -1) }
    #expect(throws: NovelForgeKeyError.opIndexOutOfRange(Int.min)) { try NovelForgeKey(novel: Self.novel, .proposalChange(proposal: SchemaFixture.proposal, index: .min)) }
    #expect(
      try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: SchemaFixture.proposal, index: 0).components == .proposalChange(proposal: SchemaFixture.proposal, index: 0))
  }

  @Test func shouldRefuseAMalformedStoredProposalChangeKey() throws {
    let ref = try NovelForgeKey.proposalChange(novel: Self.novel, proposal: SchemaFixture.proposal, index: 3)
    let novel = JSONValue.string(Self.novel.uuidString.lowercased())
    let proposal = JSONValue.string(SchemaFixture.proposal.uuidString.lowercased())
    let malformed: [JSONValue] = [
      ["novel": novel, "proposal": .string(SchemaFixture.proposal.uuidString), "index": 3], ["novel": novel, "proposal": proposal, "index": "3"],
      ["novel": novel, "proposal": proposal], ["novel": novel, "proposal": proposal, "index": 3, "op": 3], ["novel": novel, "proposal": "aria", "index": 3],
    ]
    for value in malformed {
      #expect(throws: NovelForgeKeyError.self) { try NovelForgeKey(stored: value, of: ref) }
    }
    #expect(throws: NovelForgeKeyError.opIndexOutOfRange(-3)) { try NovelForgeKey(stored: ["novel": novel, "proposal": proposal, "index": -3], of: ref) }
    #expect(throws: NovelForgeKeyError.keyMismatch(ref)) { try NovelForgeKey(stored: ["novel": novel, "proposal": proposal, "index": 4], of: ref) }
  }

  @Test func shouldMergeTwoDevicesRecordingTheSameChangeIntoOneRecord() async throws {
    let devices = try Devices()
    for store in devices.both {
      let key = try NovelForgeKey.proposalChangeKey(novel: Self.novel, proposal: SchemaFixture.proposal, index: 1)
      try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "status": "applied"], in: store)
      devices.clock.advance()
    }
    try await devices.exchange()
    for store in devices.both { #expect(try await SchemaFixture.count(.proposalChange, in: store) == 1) }
  }
}
