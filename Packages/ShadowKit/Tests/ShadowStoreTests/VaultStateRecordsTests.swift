import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

private let draftRef = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

private func randomState(_ generator: inout SeededGenerator, registry: SchemaRegistry = Fixture.v1) -> VaultState {
  var factory = ChangeFactory()
  var state = Fixture.state(factory.changes(&generator), registry)
  if generator.chance(0.5) { state = state.retained(registry: registry) }
  for _ in 0..<generator.int(in: 0...2) { state.keepOpaque(generator.opaqueLine()) }
  return state
}

@Suite("VaultState records")
struct VaultStateRecordsTests {
  @Test("should rebuild the exact state from its records and opaque lines")
  func shouldRebuildExactState() throws {
    try forAll(iterations: 300) { generator in
      let registry = generator.chance(0.5) ? Fixture.v1 : Fixture.v2
      let state = randomState(&generator, registry: registry)
      let rebuilt = Fixture.rebuilt(state, registry)
      try #require(rebuilt == state)
      try #require(rebuilt.digest == state.digest)
    }
  }

  @Test("should give byte-equal records for equal states built in different orders")
  func shouldBeDeterministic() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator)
      let first = Fixture.state(changes).records(schema: 7).map { $0.canonicalBytes() }
      let second = Fixture.state(generator.withDuplicates(changes)).records(schema: 7).map { $0.canonicalBytes() }
      try #require(first == second)
    }
  }

  @Test("should equal the join when the records of two states are applied to one state")
  func shouldMatchJoin() throws {
    try forAll(iterations: 300) { generator in
      let a = randomState(&generator)
      let b = randomState(&generator)
      var combined = Fixture.state(a.records(schema: 1) + b.records(schema: 1))
      for line in a.opaqueLines + b.opaqueLines { combined.keepOpaque(line) }
      try #require(combined == a.merging(b))
    }
  }

  @Test("should stamp synthesised records with the schema and a version 8 id derived from their content")
  func shouldDeriveSynthesisedIDs() throws {
    try forAll(iterations: 300) { generator in
      let state = randomState(&generator)
      let records = state.records(schema: 5)
      let foreign = Set(state.foreign)
      for record in records where !foreign.contains(record) {
        try #require(record.schema == 5)
        let bytes = withUnsafeBytes(of: record.id.uuid) { Array($0) }
        try #require(bytes[6] >> 4 == 8)
        try #require(bytes[8] & 0xC0 == 0x80)
      }
      try #require(records.map(\.id) == state.records(schema: 5).map(\.id))
    }
  }

  @Test("should write one revise per distinct pointer clock and one plain revise for an unnamed revision")
  func shouldWriteMinimalRevises() throws {
    let named = RevisionItem(parent: nil, body: "named", created: Fixture.clock(1), generation: 0)
    let unnamed = RevisionItem(parent: nil, body: "unnamed", created: Fixture.clock(2), generation: 1)
    let state = Fixture.state([
      Fixture.revise(named, clock: Fixture.clock(5), marks: ["approved"]), Fixture.revise(unnamed, clock: Fixture.clock(3), head: false),
      Fixture.change(.set, Fixture.draft, draftRef.key, clock: Fixture.clock(4), fields: ["title": "t"]),
    ])
    let records = state.records(schema: 1)
    try #require(records.count == 3)
    #expect(records[0].kind == .set && records[0].fields == ["title": "t"] && records[0].clock == Fixture.clock(4))
    let revises = records.dropFirst().sorted { $0.clock < $1.clock }
    #expect(revises[0].fields["revision"] == .string(unnamed.id) && revises[0].clock == unnamed.created && revises[0].fields["head"] == false)
    #expect(revises[0].fields["marks"] == nil)
    #expect(revises[1].fields["revision"] == .string(named.id) && revises[1].clock == Fixture.clock(5) && revises[1].fields["head"] == true)
    #expect(revises[1].fields["marks"] == ["approved"])
    var split = state
    split.apply(Fixture.revise(named, clock: Fixture.clock(6), head: false, marks: ["approved"]), registry: Fixture.v1)
    #expect(split.records(schema: 1).filter { $0.kind == .revise && $0.fields["revision"] == .string(named.id) }.count == 2)
    #expect(Fixture.rebuilt(split) == split)
  }
}
