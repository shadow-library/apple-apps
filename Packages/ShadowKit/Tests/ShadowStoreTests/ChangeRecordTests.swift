import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

private func decodeFailure(_ json: JSONValue) -> ChangeRecordError? {
  do {
    _ = try ChangeRecord(json: json)
    return nil
  } catch {
    return error
  }
}

private func replacing(_ name: String, with value: JSONValue?, in record: ChangeRecord) -> JSONValue {
  var members = record.json.objectValue ?? [:]
  members[name] = value
  return .object(members)
}

@Suite("ChangeRecord")
struct ChangeRecordTests {
  private let sample = Fixture.change(
    .set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(5, 3, replica: 1), schema: 3, fields: ["title": "The Ember Court", "status": "draft"],
    id: must(UUID(uuidString: "0193A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B"), "uuid"))

  @Test("should encode the documented member layout as canonical JSON")
  func shouldEncodeCanonicalLayout() {
    let text = String(decoding: sample.canonicalBytes(), as: UTF8.self)
    let expected =
      "{\"clock\":\"2023-11-14T22:13:20.005Z-0003-00000000-0000-0000-0000-00000000000b\",\"entity\":\"note\","
      + "\"fields\":{\"status\":\"draft\",\"title\":\"The Ember Court\"},\"id\":\"0193a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b\",\"key\":\"k1\",\"kind\":\"set\",\"schema\":3}"
    #expect(text == expected)
  }

  @Test("should round-trip random records through JSON and canonical bytes")
  func shouldRoundTripRandomRecords() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      for record in factory.changes(&generator, count: 1...5) {
        let decoded = try ChangeRecord(json: try CanonicalJSON.decode(record.canonicalBytes()))
        try #require(decoded == record)
        try #require(decoded.canonicalBytes() == record.canonicalBytes())
      }
    }
  }

  @Test("should reject a value that is not an object")
  func shouldRejectNonObject() {
    #expect(decodeFailure(["a"]) == .notAnObject)
    #expect(decodeFailure("record") == .notAnObject)
  }

  @Test("should reject a missing member", arguments: ["clock", "entity", "fields", "id", "key", "kind", "schema"])
  func shouldRejectMissingMember(_ name: String) {
    #expect(decodeFailure(replacing(name, with: nil, in: sample)) == .missingMember(name))
  }

  @Test("should reject an unexpected member")
  func shouldRejectUnexpectedMember() {
    #expect(decodeFailure(replacing("extra", with: 1, in: sample)) == .unexpectedMember("extra"))
  }

  @Test(
    "should reject an invalid member",
    arguments: [
      ("id", "0193A1B2-C3D4-7E5F-8A9B-0C1D2E3F4A5B"), ("id", "not-a-uuid"), ("clock", "2026-11-16"), ("clock", 5), ("schema", -1), ("schema", "3"),
      ("entity", "Note"), ("key", "K1"), ("kind", "delete"), ("kind", "Set"), ("fields", ["a"]), ("fields", nil),
    ] as [(String, JSONValue)])
  func shouldRejectInvalidMember(_ name: String, _ value: JSONValue) {
    #expect(decodeFailure(replacing(name, with: value, in: sample)) == .invalidMember(name))
  }

  @Test("should compare records by canonical bytes, not by Unicode equivalence")
  func shouldCompareByBytes() {
    let composed = Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["title": "\u{E9}"], id: sample.id)
    let decomposed = Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["title": "e\u{301}"], id: sample.id)
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
  }

  @Test("should expose a stable code for every error")
  func shouldExposeStableCodes() {
    #expect(ChangeRecordError.notAnObject.code == "change_record.not_an_object")
    #expect(ChangeRecordError.missingMember("id").code == "change_record.missing_member")
    #expect(ChangeRecordError.unexpectedMember("x").code == "change_record.unexpected_member")
    #expect(ChangeRecordError.invalidMember("id").code == "change_record.invalid_member")
  }
}

@Suite("SchemaRegistry interpretation")
struct InterpretationTests {
  private static let key = Fixture.key("k1")
  private static let clock = Fixture.clock(1)
  private static let item = RevisionItem(parent: nil, body: "x", created: Fixture.clock(0), generation: 0)
  private static let revise = Fixture.revise(item, clock: clock, key: key).fields

  private static func reviseWith(_ changes: [String: JSONValue?]) -> ChangeRecord {
    var fields = revise
    for (name, value) in changes { fields[name] = value }
    return Fixture.change(.revise, Fixture.draft, key, clock: clock, fields: fields)
  }

  @Test("should interpret records that fit the declared shape")
  func shouldInterpretFittingRecords() {
    let registry = Fixture.v1
    let key = Self.key
    let clock = Self.clock
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.note, key, clock: clock, fields: ["title": 1, "status": "final", "origin": nil])))
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.note, key, clock: clock, schema: 99, fields: ["title": 1])))
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.note, key, clock: clock)))
    #expect(registry.isInterpretable(Fixture.change(.purge, Fixture.note, key, clock: clock)))
    #expect(registry.isInterpretable(Fixture.change(.append, Fixture.message, key, clock: clock, fields: ["anything": ["goes": true]])))
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.draft, key, clock: clock, fields: ["title": "t"])))
    #expect(registry.isInterpretable(Fixture.revise(Self.item, clock: clock, key: key)))
    #expect(registry.isInterpretable(Fixture.revise(Self.item, clock: clock, key: key, head: false, marks: ["approved"])))
    #expect(registry.isInterpretable(Self.reviseWith(["head": nil])))
  }

  @Test(
    "should treat malformed or misfitting atomic records as wholly foreign",
    arguments: [
      Fixture.change(.set, Fixture.tag, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["label": 1]),
      Fixture.change(.purge, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["reason": "x"]),
      Fixture.change(.append, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["text": "x"]),
      Fixture.change(.set, Fixture.message, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["text": "x"]),
      Fixture.change(.revise, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: revise),
      reviseWith(["revision": "v:0000"]),
      reviseWith(["body": "changed"]),
      reviseWith(["created": nil]),
      reviseWith(["created": "yesterday"]),
      reviseWith(["created": 5]),
      reviseWith(["generation": nil]),
      reviseWith(["generation": -1]),
      reviseWith(["generation": "1"]),
      reviseWith(["generation": [1]]),
      reviseWith(["revision": nil]),
      reviseWith(["body": nil]),
      reviseWith(["parent": 3]),
      reviseWith(["head": "yes"]),
      reviseWith(["marks": "approved"]),
      reviseWith(["marks": [1]]),
      reviseWith(["marks": ["reviewed"]]),
      reviseWith(["marks": ["approved", "approved"]]),
      reviseWith(["marks": ["head"]]),
      reviseWith(["language": "en"]),
    ])
  func shouldTreatAtomicMisfitsAsForeign(_ change: ChangeRecord) {
    #expect(Fixture.v1.foreignPart(of: change) == change)
    let state = Fixture.state([change])
    #expect(state.foreign == [change])
    #expect(state.refs.isEmpty)
  }

  @Test(
    "should apply the declared fields of a set and keep the rest as a foreign remainder",
    arguments: [
      (Fixture.note, ["title": 1, "pinned": 2], ["pinned": 2]),
      (Fixture.note, ["title": 1, "status": "archived"], ["status": "archived"]),
      (Fixture.note, ["status": 1, "origin": "o"], ["status": 1]),
      (Fixture.note, ["ti\u{301}tle": 1, "title": 2], ["ti\u{301}tle": 1]),
      (Fixture.draft, ["title": 1, "head": "v:x"], ["head": "v:x"]),
      (Fixture.draft, ["title": 1, "approved": "v:x"], ["approved": "v:x"]),
    ] as [(EntityKind, [String: JSONValue], [String: JSONValue])])
  func shouldSplitSetRecords(_ entity: EntityKind, _ fields: [String: JSONValue], _ remainder: [String: JSONValue]) throws {
    let change = Fixture.change(.set, entity, Self.key, clock: Self.clock, fields: fields)
    let expected = Fixture.change(.set, entity, Self.key, clock: Self.clock, fields: remainder, id: change.id)
    #expect(Fixture.v1.foreignPart(of: change) == expected)
    let state = Fixture.state([change])
    #expect(state.foreign == [expected])
    #expect(state.refs == [EntityRef(kind: entity, key: Self.key)])
  }

  @Test("should keep a set with no declared field wholly foreign without creating the entity")
  func shouldNotCreateEntityFromUnknownFieldsAlone() {
    let change = Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock, fields: ["pinned": 1])
    let state = Fixture.state([change])
    #expect(state.foreign == [change])
    #expect(state.refs.isEmpty)
    #expect(Fixture.state([Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock)]).isEmpty)
  }

  @Test("should match a declared field name only by its exact bytes")
  func shouldMatchFieldNamesByBytes() {
    let registry = SchemaRegistry(version: 1, entities: [EntitySchema(kind: Fixture.note, shape: .record(fields: ["caf\u{E9}": .register]), syncClass: .general)])
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock, fields: ["caf\u{E9}": 1])))
    #expect(!registry.isInterpretable(Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock, fields: ["cafe\u{301}": 1])))
  }

  @Test("should match monotone values only by their exact bytes")
  func shouldMatchMonotoneValuesByBytes() {
    let registry = SchemaRegistry(
      version: 1, entities: [EntitySchema(kind: Fixture.note, shape: .record(fields: ["status": .monotone(order: ["\u{E9}t\u{E9}"])]), syncClass: .general)])
    #expect(registry.isInterpretable(Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock, fields: ["status": "\u{E9}t\u{E9}"])))
    #expect(!registry.isInterpretable(Fixture.change(.set, Fixture.note, Self.key, clock: Self.clock, fields: ["status": "e\u{301}te\u{301}"])))
  }

  @Test("should refuse a mark named head, a mark that is also a field, a repeated mark, a head field, a zero limit and a repeated monotone value")
  func shouldRefuseInvalidSchemas() async {
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: [:], marks: ["head"], retention: .keepAll), syncClass: .general)
    }
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: ["approved": .register], marks: ["approved"], retention: .keepAll), syncClass: .general)
    }
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: [:], marks: ["a", "a"], retention: .keepAll), syncClass: .general)
    }
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: ["head": .register], marks: [], retention: .keepAll), syncClass: .general)
    }
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(0)), syncClass: .general)
    }
    await #expect(processExitsWith: .failure) {
      _ = EntitySchema(kind: Fixture.note, shape: .record(fields: ["status": .monotone(order: ["a", "b", "a"])]), syncClass: .general)
    }
  }
}

@Suite("RevisionItem")
struct RevisionItemTests {
  private let item = RevisionItem(parent: "v:parent", body: ["text": "Chapter one"], created: Fixture.clock(5, 3, replica: 1), generation: 7)

  @Test("should derive the id from the canonical item bytes")
  func shouldDeriveStableID() {
    #expect(
      String(decoding: item.canonicalBytes, as: UTF8.self)
        == "{\"body\":{\"text\":\"Chapter one\"},\"created\":\"2023-11-14T22:13:20.005Z-0003-00000000-0000-0000-0000-00000000000b\",\"generation\":7,\"parent\":\"v:parent\"}")
    #expect(item.id == "v:7e76d2818353d7d9711d14cb3099ceaac9b50ba0")
    #expect(EntityKey(item.id) != nil)
  }

  @Test("should change the id when any part of the item changes")
  func shouldBeSensitiveToEachPart() {
    let variants = [
      RevisionItem(parent: nil, body: item.body, created: item.created, generation: 7), RevisionItem(parent: "v:other", body: item.body, created: item.created, generation: 7),
      RevisionItem(parent: item.parent, body: ["text": "Chapter one."], created: item.created, generation: 7),
      RevisionItem(parent: item.parent, body: item.body, created: Fixture.clock(5, 3), generation: 7),
      RevisionItem(parent: item.parent, body: ["text": "Chapter on\u{E9}"], created: item.created, generation: 7),
      RevisionItem(parent: item.parent, body: ["text": "Chapter one\u{301}"], created: item.created, generation: 7),
      RevisionItem(parent: item.parent, body: item.body, created: item.created, generation: 8),
    ]
    #expect(Set(([item] + variants).map(\.id)).count == variants.count + 1)
  }

  @Test("should write a well-formed revise record")
  func shouldWriteReviseRecord() {
    let record = ChangeRecord.revise(
      id: UUID(), clock: Fixture.clock(9), schema: 4, entity: Fixture.draft, key: Fixture.key("d1"), item: item, head: false, marks: ["approved"])
    #expect(record.kind == .revise)
    #expect(record.schema == 4)
    #expect(record.fields["revision"] == .string(item.id))
    #expect(record.fields["created"] == .string(item.created.description))
    #expect(record.fields["head"] == false)
    #expect(record.fields["marks"] == ["approved"])
    #expect(Fixture.v1.isInterpretable(record))
  }
}
