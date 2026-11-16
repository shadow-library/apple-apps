import ShadowStore
import Testing

private let draft = Fixture.draft
private let note = Fixture.note

private func registry(version: Int = 1, _ entities: EntitySchema...) -> SchemaRegistry {
  SchemaRegistry(version: version, entities: entities)
}

private func record(_ fields: [String: FieldRule], kind: EntityKind = note, syncClass: SyncClass = .general) -> EntitySchema {
  EntitySchema(kind: kind, shape: .record(fields: fields), syncClass: syncClass)
}

private func revisioned(_ fields: [String: FieldRule] = [:], marks: [String] = [], retention: RevisionRetention = .keepNewest(3)) -> EntitySchema {
  EntitySchema(kind: draft, shape: .revisioned(fields: fields, marks: marks, retention: retention), syncClass: .general)
}

private struct Case: Sendable, CustomTestStringConvertible {
  let name: String
  let earlier: SchemaRegistry
  let later: SchemaRegistry
  let expected: [String]

  var testDescription: String { name }
}

private let cases: [Case] = [
  Case(name: "identical", earlier: registry(record(["title": .register])), later: registry(record(["title": .register])), expected: []),
  Case(
    name: "new kind, field and mark", earlier: registry(record(["title": .register]), revisioned(marks: ["a"])),
    later: registry(version: 2, record(["title": .register, "pinned": .register]), revisioned(["title": .register], marks: ["a", "b"]), record([:], kind: Fixture.tag)),
    expected: []),
  Case(
    name: "monotone order extended at both ends", earlier: registry(record(["status": .monotone(order: ["b", "c"])])),
    later: registry(record(["status": .monotone(order: ["a", "b", "x", "c", "d"])])), expected: []),
  Case(
    name: "keep newest shrinks or becomes bounded", earlier: registry(revisioned(retention: .keepNewest(5))), later: registry(revisioned(retention: .keepNewest(2))),
    expected: []),
  Case(name: "keep all becomes bounded", earlier: registry(revisioned(retention: .keepAll)), later: registry(revisioned(retention: .keepNewest(2))), expected: []),
  Case(
    name: "lower version", earlier: registry(version: 3, record([:])), later: registry(version: 2, record([:])),
    expected: ["version 2 is lower than the earlier version 3"]),
  Case(name: "kind removed", earlier: registry(record([:]), revisioned()), later: registry(record([:])), expected: ["kind draft was removed"]),
  Case(
    name: "shape changed", earlier: registry(revisioned()), later: registry(record([:], kind: draft)), expected: ["kind draft changed shape from revisioned to record"]),
  Case(
    name: "sync class changed", earlier: registry(record([:])), later: registry(record([:], syncClass: .health)),
    expected: ["kind note changed sync class from general to health"]),
  Case(name: "field removed", earlier: registry(record(["title": .register])), later: registry(record([:])), expected: ["field note.title was removed"]),
  Case(
    name: "field renamed by normalisation", earlier: registry(record(["caf\u{E9}": .register])), later: registry(record(["cafe\u{301}": .register])),
    expected: ["field note.caf\u{E9} was removed"]),
  Case(
    name: "rule changed", earlier: registry(record(["title": .register])), later: registry(record(["title": .firstWriterWins])),
    expected: ["field note.title changed rule from register to first writer wins"]),
  Case(
    name: "monotone order reordered", earlier: registry(record(["status": .monotone(order: ["a", "b"])])), later: registry(record(["status": .monotone(order: ["b", "a"])])),
    expected: ["field note.status changed rule from monotone [a, b] to monotone [b, a]"]),
  Case(
    name: "monotone value removed", earlier: registry(record(["status": .monotone(order: ["a", "b"])])), later: registry(record(["status": .monotone(order: ["a"])])),
    expected: ["field note.status changed rule from monotone [a, b] to monotone [a]"]),
  Case(name: "mark removed", earlier: registry(revisioned(marks: ["a", "b"])), later: registry(revisioned(marks: ["b"])), expected: ["mark draft.a was removed"]),
  Case(
    name: "keep newest grows", earlier: registry(revisioned(retention: .keepNewest(2))), later: registry(revisioned(retention: .keepNewest(3))),
    expected: ["retention of draft grew from the newest 2 to the newest 3"]),
  Case(
    name: "keep newest becomes keep all", earlier: registry(revisioned(retention: .keepNewest(2))), later: registry(revisioned(retention: .keepAll)),
    expected: ["retention of draft changed from the newest 2 to keeping all"]),
  Case(
    name: "several problems at once", earlier: registry(record(["title": .register, "origin": .firstWriterWins]), revisioned(marks: ["a"])),
    later: registry(record(["title": .firstWriterWins]), revisioned()),
    expected: ["mark draft.a was removed", "field note.origin was removed", "field note.title changed rule from register to first writer wins"]),
]

@Suite("SchemaRegistry compatibility")
struct SchemaCompatibilityTests {
  @Test("should list exactly the non-additive changes", arguments: cases)
  fileprivate func shouldListIncompatibilities(_ testCase: Case) {
    #expect(testCase.later.incompatibilities(with: testCase.earlier) == testCase.expected)
  }

  @Test("should accept the fixture registries as an additive history")
  func shouldAcceptFixtureHistory() {
    #expect(Fixture.vMid.incompatibilities(with: Fixture.v1).isEmpty)
    #expect(Fixture.v2.incompatibilities(with: Fixture.vMid).isEmpty)
    #expect(Fixture.v2.incompatibilities(with: Fixture.v1).isEmpty)
    #expect(!Fixture.v1.incompatibilities(with: Fixture.v2).isEmpty)
  }
}
