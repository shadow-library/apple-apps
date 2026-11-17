import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let golden = SchemaRegistry(
  version: 7,
  entities: [
    EntitySchema(
      kind: must(EntityKind("page"), "page"), shape: .revisioned(fields: ["title": .register], marks: ["reviewed", "approved"], retention: .keepNewest(50)),
      syncClass: .health),
    EntitySchema(
      kind: Fixture.note, shape: .record(fields: ["title": .register, "status": .monotone(order: ["draft", "final"]), "origin": .firstWriterWins]), syncClass: .general),
    EntitySchema(kind: Fixture.message, shape: .appended, syncClass: .activity),
    EntitySchema(kind: must(EntityKind("log"), "log"), shape: .revisioned(fields: [:], marks: [], retention: .keepAll), syncClass: .general),
  ])

private let goldenDescription =
  #"{"format":"com.shadow.library.shadowstore.schema-registry","format_version":1,"kinds":[{"fields":[],"kind":"log","marks":[],"retention":"all","shape":"revisioned","sync_class":"general"},"#
  + #"{"kind":"message","shape":"appended","sync_class":"activity"},{"fields":[{"name":"origin","rule":{"kind":"first_writer_wins"}},"#
  + #"{"name":"status","rule":{"kind":"monotone","order":["draft","final"]}},{"name":"title","rule":{"kind":"register"}}],"kind":"note","shape":"record","#
  + #""sync_class":"general"},{"fields":[{"name":"title","rule":{"kind":"register"}}],"kind":"page","marks":["approved","reviewed"],"retention":50,"#
  + #""shape":"revisioned","sync_class":"health"}],"version":7}"#

private let names = ["title", "status", "\u{E9}", "e\u{301}", "a", "B", "approved", "z\u{1F600}"]

private func randomRegistry(_ generator: inout SeededGenerator) -> SchemaRegistry {
  let kinds = Set((0..<generator.int(in: 0...5)).map { _ in must(EntityKind(generator.pick(from: ["note", "draft", "message", "a1", "z_9", "page"])), "kind") })
  let schemas = kinds.map { kind -> EntitySchema in
    var fields = [String: FieldRule]()
    for _ in 0..<generator.int(in: 0...4) {
      let order = Array(Set(generator.shuffled(["draft", "review", "final", "\u{E9}"]).prefix(generator.int(in: 0...4)).map(ExactString.init(_:)))).map(\.value)
      fields[generator.pick(from: names)] = generator.pick(from: [FieldRule.register, .firstWriterWins, .monotone(order: generator.shuffled(order))])
    }
    let syncClass = generator.pick(from: SyncClass.allCases)
    switch generator.int(in: 0...2) {
    case 0: return EntitySchema(kind: kind, shape: .record(fields: fields), syncClass: syncClass)
    case 1: return EntitySchema(kind: kind, shape: .appended, syncClass: syncClass)
    default:
      let candidates = (names + ["reviewed"]).filter { name in !fields.keys.contains { $0.utf8.elementsEqual(name.utf8) } }
      let marks = Array(Set(generator.shuffled(candidates).prefix(generator.int(in: 0...3)).map(ExactString.init(_:)))).map(\.value)
      let retention: RevisionRetention = generator.chance(0.3) ? .keepAll : .keepNewest(generator.int(in: 1...60))
      return EntitySchema(kind: kind, shape: .revisioned(fields: fields, marks: generator.shuffled(marks), retention: retention), syncClass: syncClass)
    }
  }
  return SchemaRegistry(version: generator.int(in: 0...1_000), entities: schemas)
}

private struct Normalised: Equatable {
  let kind: EntityKind
  let shape: String
  let fields: [String: FieldRule]
  let marks: [ExactString]
  let retention: RevisionRetention?
  let syncClass: SyncClass

  init(_ schema: EntitySchema) {
    kind = schema.kind
    shape = schema.shape.name
    fields = schema.shape.fields
    marks = schema.shape.marks.map(ExactString.init(_:)).sorted()
    if case .revisioned(_, _, let retention) = schema.shape { self.retention = retention } else { retention = nil }
    syncClass = schema.syncClass
  }
}

private func expectRefused(_ text: String, _ expected: RegistryDescriptionError) {
  #expect(throws: expected) { try SchemaRegistry(canonicalDescription: Data(text.utf8)) }
}

@Suite("SchemaRegistry canonical description")
struct RegistryDescriptionTests {
  @Test("should round-trip any registry to an equal one with byte-identical description")
  func shouldRoundTrip() throws {
    try forAll(iterations: 300, seed: 0xDE5C) { generator in
      let registry = randomRegistry(&generator)
      let description = registry.canonicalDescription()
      let decoded = try SchemaRegistry(canonicalDescription: description)
      try #require(decoded.version == registry.version)
      try #require(decoded.schemas.map(Normalised.init) == registry.schemas.map(Normalised.init))
      try #require(decoded.canonicalDescription() == description)
      try #require(decoded.incompatibilities(with: registry).isEmpty && registry.incompatibilities(with: decoded).isEmpty)
    }
  }

  @Test("should match the pinned golden description")
  func shouldMatchGolden() throws {
    #expect(String(decoding: golden.canonicalDescription(), as: UTF8.self) == goldenDescription)
    #expect(try SchemaRegistry(canonicalDescription: Data(goldenDescription.utf8)).canonicalDescription() == golden.canonicalDescription())
  }

  @Test("should refuse a description that is not canonical, of another format or malformed, without trapping")
  func shouldRefuseMalformedDescriptions() {
    let header = #"{"format":"com.shadow.library.shadowstore.schema-registry","format_version":1,"kinds":["#
    let kind = { (members: String) in header + "{" + members + #"}],"version":1}"# }
    expectRefused(#"{ "version": 1 }"#, .notCanonical)
    expectRefused(#"{"format":"other","format_version":1,"kinds":[],"version":1}"#, .unsupportedFormat)
    expectRefused(#"{"format":"com.shadow.library.shadowstore.schema-registry","format_version":2,"kinds":[],"version":1}"#, .unsupportedFormat)
    let malformed = [
      kind(#""kind":"Note","shape":"appended","sync_class":"general""#),
      kind(#""kind":"note","shape":"tree","sync_class":"general""#),
      kind(#""kind":"note","shape":"appended","sync_class":"secret""#),
      kind(#""extra":1,"kind":"note","shape":"appended","sync_class":"general""#),
      kind(#""fields":[{"name":"head","rule":{"kind":"register"}}],"kind":"d","marks":[],"retention":1,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[],"kind":"d","marks":["head"],"retention":1,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[{"name":"a","rule":{"kind":"register"}}],"kind":"d","marks":["a"],"retention":1,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[],"kind":"d","marks":["b","a"],"retention":1,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[],"kind":"d","marks":["a","a"],"retention":1,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[],"kind":"d","marks":[],"retention":0,"shape":"revisioned","sync_class":"general""#),
      kind(#""fields":[{"name":"b","rule":{"kind":"register"}},{"name":"a","rule":{"kind":"register"}}],"kind":"n","shape":"record","sync_class":"general""#),
      kind(#""fields":[{"name":"é","rule":{"kind":"register"}},{"name":"é","rule":{"kind":"register"}}],"kind":"n","shape":"record","sync_class":"general""#),
      kind(#""fields":[{"name":"s","rule":{"kind":"monotone","order":["a","a"]}}],"kind":"n","shape":"record","sync_class":"general""#),
      header + #"{"kind":"n","shape":"appended","sync_class":"general"},{"kind":"n","shape":"appended","sync_class":"general"}],"version":1}"#,
      header + #"],"version":"one"}"#,
    ]
    for text in malformed {
      #expect(throws: RegistryDescriptionError.self, "\(text)") { try SchemaRegistry(canonicalDescription: Data(text.utf8)) }
    }
  }
}
