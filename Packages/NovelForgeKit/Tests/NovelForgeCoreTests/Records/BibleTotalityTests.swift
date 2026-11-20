import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import ShadowText
import Testing

@testable import NovelForgeCore

private let wrongType = JSONValue.array([.null])

private func foreignKindKey<S: RemovableSubject>(_: S.Type, foreign: NovelForgeKey) async throws {
  let store = try SchemaFixture.store()
  var generator = SeededGenerator(seed: 0xD3)
  let record = fresh(S.self, &generator)
  var members = record.storedMembers
  members["natural_key"] = foreign.stored
  guard case .unreadable(.naturalKey) = try await reading(S.self, record, members, in: store) else {
    Issue.record("a natural key of another kind was accepted")
    return
  }
}

@Suite("Bible record totality", TestTimeLimit.property)
struct BibleTotalityTests {
  @Test func shouldReadASecretTotally() async throws { try await totality(SecretSubject.self, seed: 0xE6, anyJSON: ["unlock"]) }
  @Test func shouldReadAnEntityTotally() async throws { try await totality(EntitySubject.self, seed: 0xE7, anyJSON: ["attributes"]) }
  @Test func shouldReadAManualRevealTotally() async throws { try await totality(CharacterKnowledgeSubject.self, seed: 0xE8) }

  @Test func shouldReportASecretWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(SecretSubject.self) }
  @Test func shouldReportAnEntityWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(EntitySubject.self) }
  @Test func shouldReportAManualRevealWhoseNaturalKeyBelongsToAnotherRecordAsUnreadable() async throws { try await mismatchedNaturalKey(CharacterKnowledgeSubject.self) }

  @Test func shouldReportANaturalKeyOfAnotherKindAsUnreadable() async throws {
    let novel = SchemaFixture.novel
    try await foreignKindKey(SecretSubject.self, foreign: NovelForgeKey.entityKey(novel: novel, entity: "aria"))
    try await foreignKindKey(EntitySubject.self, foreign: NovelForgeKey.secretKey(novel: novel, secret: "aria"))
    try await foreignKindKey(CharacterKnowledgeSubject.self, foreign: NovelForgeKey.secretKey(novel: novel, secret: "aria"))
  }

  @Test func shouldReportAManualRevealWhoseKeyHasOnlyOneHalfAsUnreadable() async throws {
    let store = try SchemaFixture.store()
    let record = CharacterKnowledgeRecord(novel: SchemaFixture.novel, fact: "heir", entity: "aria", reveal: ManualReveal(chapter: 2))
    var members = record.storedMembers
    members["natural_key"] = .object(["novel": .string(SchemaFixture.novel.uuidString.lowercased()), "fact": "heir"])
    guard case .unreadable(.naturalKey(.malformedKey)) = try await reading(CharacterKnowledgeSubject.self, record, members, in: store) else {
      Issue.record("a half key was accepted")
      return
    }
  }

  @Test(arguments: [
    JSONValue.object([:]), ["chapter": "3"], ["chapter": nil], ["note": "n"], ["chapter": 3, "note": 7], .null, "3",
  ])
  func shouldReportAMalformedManualRevealAsUnreadable(_ reveal: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let record = CharacterKnowledgeRecord(novel: SchemaFixture.novel, fact: "heir", entity: "aria", reveal: ManualReveal(chapter: 2))
    var members = record.storedMembers
    members["reveal"] = reveal
    let result = try await reading(CharacterKnowledgeSubject.self, record, members, in: store)
    #expect(result == .unreadable(.invalid(field: "reveal")))
  }

  @Test(arguments: [JSONValue.array([.int(1)]), ["clues": "a"], ["terms": [1]], ["clues": [["x"]]], "text"])
  func shouldReportMalformedCluesAndTermsAsUnreadable(_ value: JSONValue) async throws {
    let store = try SchemaFixture.store()
    let record = SecretRecord(novel: SchemaFixture.novel, secret: "heir", text: "t")
    var members = record.storedMembers
    members["clues_and_terms"] = value
    #expect(try await reading(SecretSubject.self, record, members, in: store) == .unreadable(.invalid(field: "clues_and_terms")))
  }

  @Test func shouldKeepNewerMembersOfCluesAndTermsReadable() async throws {
    let store = try SchemaFixture.store()
    let record = SecretRecord(novel: SchemaFixture.novel, secret: "heir", text: "t")
    var members = record.storedMembers
    members["clues_and_terms"] = ["clues": ["a ring"], "terms": nil, "weight": 3]
    let read = try #require(try await reading(SecretSubject.self, record, members, in: store).entry?.record)
    #expect(read.cluesAndTerms?.clues == ["a ring"])
    #expect(read.cluesAndTerms?.unrecognised == ["weight": 3])
  }

  @Test func shouldReadHandWrittenSecretStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = NovelForgeKey.secretKey(novel: SchemaFixture.novel, secret: "heir")
    try await SchemaFixture.set(
      key.ref,
      [
        "natural_key": key.stored, "removed": false, "text": "The heir lives", "subjects": ["aria"], "constraint_note": nil, "writer_note": "hint",
        "clues_and_terms": ["clues": ["a cold ring"], "terms": ["heir"]], "reveal_chapter": 12, "unlock": ["all": [["milestone": "rank-two"]]], "source": "import",
      ], in: store)
    let expected = SecretRecord(
      novel: SchemaFixture.novel, secret: "heir", text: "The heir lives", subjects: ["aria"], writerNote: "hint",
      cluesAndTerms: CluesAndTerms(clues: ["a cold ring"], terms: ["heir"]), revealChapter: 12, unlock: ["all": [["milestone": "rank-two"]]], source: .known(.import))
    #expect(try await Harness.read(key.ref, as: SecretRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldReadHandWrittenEntityStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = NovelForgeKey.entityKey(novel: SchemaFixture.novel, entity: "aria")
    try await SchemaFixture.set(
      key.ref,
      [
        "natural_key": key.stored, "removed": true, "type": "power_rule", "name": "Aria", "attributes": ["age": 30], "significance": "major", "status": nil, "origin": "seeded",
        "notes": nil, "motivation": "home", "body": nil, "appearance": "tall", "wiki_visibility": "hidden",
      ], in: store)
    let expected = EntityRecord(
      novel: SchemaFixture.novel, entity: "aria", type: .known(.powerRule), name: "Aria", attributes: ["age": 30], significance: .known(.major), origin: .known(.seeded),
      motivation: "home", appearance: "tall", wikiVisibility: .known(.hidden))
    #expect(try await Harness.read(key.ref, as: EntityRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: true)))
  }

  @Test func shouldReadHandWrittenManualRevealStateFromTheFieldNames() async throws {
    let store = try SchemaFixture.store()
    let key = NovelForgeKey.characterKnowledgeKey(novel: SchemaFixture.novel, fact: "heir", entity: "aria")
    try await SchemaFixture.set(key.ref, ["natural_key": key.stored, "removed": false, "reveal": ["chapter": 5, "note": "told by the queen"]], in: store)
    let expected = CharacterKnowledgeRecord(novel: SchemaFixture.novel, fact: "heir", entity: "aria", reveal: ManualReveal(chapter: 5, note: "told by the queen"))
    #expect(try await Harness.read(key.ref, as: CharacterKnowledgeRecord.self, in: store) == .readable(RecordEntry(record: expected, isRemoved: false)))
  }

  @Test func shouldCarryUnknownEnumTextThroughARestoreOfAnEntity() async throws {
    let store = try SchemaFixture.store()
    let record = EntityRecord(
      novel: SchemaFixture.novel, entity: "future", type: .unknown("x_vehicle"), name: "Future", significance: .unknown("x_epic"), wikiVisibility: .unknown("x_paywalled"))
    _ = try await Harness.create(record, in: store)
    _ = try await Harness.remove(record, in: store)
    let carried = try #require(try await Harness.read(record.ref, as: EntityRecord.self, in: store).entry)
    #expect(carried.isRemoved)
    _ = try await Harness.restore(carried.record, in: store)
    let stored = try await SchemaFixture.record(record.ref, in: store)
    #expect(stored[field: "type"]?.value == "x_vehicle")
    #expect(stored[field: "significance"]?.value == "x_epic")
    #expect(stored[field: "wiki_visibility"]?.value == "x_paywalled")
  }
}
