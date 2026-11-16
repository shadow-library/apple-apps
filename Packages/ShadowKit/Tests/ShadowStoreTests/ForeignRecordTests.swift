import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private func sortedByBytes(_ records: [ChangeRecord]) -> [ChangeRecord] {
  Set(records).sorted { $0.canonicalBytes().lexicographicallyPrecedes($1.canonicalBytes()) }
}

private func expectedForeign(_ changes: [ChangeRecord], _ registry: SchemaRegistry) -> [ChangeRecord] {
  let purged = Set(changes.filter { $0.kind == .purge && $0.fields.isEmpty }.map(\.ref))
  return sortedByBytes(changes.compactMap(registry.foreignPart(of:)).filter { $0.kind == .purge || !purged.contains($0.ref) })
}

private func knownPart(_ change: ChangeRecord, _ registry: SchemaRegistry) -> ChangeRecord? {
  guard let remainder = registry.foreignPart(of: change) else { return change }
  guard remainder != change else { return nil }
  let fields = change.fields.filter { remainder.fields[$0.key] == nil }
  return ChangeRecord(id: change.id, clock: change.clock, schema: change.schema, entity: change.entity, key: change.key, kind: change.kind, fields: fields)
}

private func fresh(_ changes: [ChangeRecord], _ registry: SchemaRegistry, _ generator: inout SeededGenerator) -> VaultState {
  Fixture.state(generator.withDuplicates(changes), registry)
}

private func partitioned(_ changes: [ChangeRecord], _ registry: SchemaRegistry, _ generator: inout SeededGenerator) -> VaultState {
  generator.split(changes, into: generator.int(in: 1...3)).map { Fixture.state(generator.shuffled($0), registry) }.reduce(VaultState()) { $0.merging($1) }
}

@Suite("Foreign records")
struct ForeignRecordTests {
  @Test("should keep the foreign part of every record verbatim without touching the interpreted state")
  func shouldKeepForeignParts() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator)
      let mixed = fresh(changes, Fixture.v1, &generator)
      let known = Fixture.state(changes.compactMap { knownPart($0, Fixture.v1) })
      try #require(mixed.foreign == expectedForeign(changes, Fixture.v1))
      try #require(known.foreign.isEmpty)
      try #require(mixed.refs == known.refs)
      for ref in known.refs { try #require(mixed.state(of: ref) == known.state(of: ref)) }
    }
  }

  @Test("should equal a fresh state under each newer registry after reinterpreting, for any order and partition")
  func shouldReinterpretAfterUpdate() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let changes = factory.changes(&generator)
      var stepwise = partitioned(changes, Fixture.v1, &generator)
      var direct = stepwise
      try stepwise.reinterpretForeign(registry: Fixture.vMid)
      try #require(stepwise == fresh(changes, Fixture.vMid, &generator))
      stepwise = stepwise.merging(partitioned(changes, Fixture.vMid, &generator))
      try stepwise.reinterpretForeign(registry: Fixture.v2)
      try direct.reinterpretForeign(registry: Fixture.v2)
      let expected = fresh(changes, Fixture.v2, &generator)
      try #require(stepwise == expected)
      try #require(direct == expected)
      try #require(direct.digest == expected.digest)
      try #require(direct.foreign == expectedForeign(changes, Fixture.v2))
      var again = direct
      try again.reinterpretForeign(registry: Fixture.v2)
      try #require(again == direct)
    }
  }

  @Test("should equal a fresh state under the newer registry for states built under two successive registries")
  func shouldReinterpretMixedRegistryStates() throws {
    let pairs = [
      (Fixture.v1, Fixture.vMid), (Fixture.vMid, Fixture.v2), (Fixture.v1, Fixture.v2), (Fixture.v2, Fixture.v2), (Fixture.v2, Fixture.vInsert), (Fixture.v1, Fixture.vInsert),
    ]
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let (older, newer) = generator.pick(from: pairs)
      let changes = factory.changes(&generator)
      let parts = generator.split(changes, into: generator.int(in: 1...4)).map { Fixture.state(generator.shuffled($0), generator.chance(0.5) ? older : newer) }
      var merged = generator.shuffled(parts).reduce(VaultState()) { $0.merging($1) }
      try merged.reinterpretForeign(registry: newer)
      try #require(merged == fresh(changes, newer, &generator))
    }
  }

  @Test("should refuse to reinterpret under a registry that is not an additive successor, leaving the state unchanged")
  func shouldRefuseNonAdditiveRegistry() throws {
    let note = Fixture.state([Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["title": "t", "status": "final"])])
    let draft = Fixture.state([Fixture.revise(RevisionItem(parent: nil, body: "b", created: Fixture.clock(1), generation: 0), clock: Fixture.clock(1), marks: ["approved"])])
    let noteSchema = { (fields: [String: FieldRule]) in EntitySchema(kind: Fixture.note, shape: .record(fields: fields), syncClass: .general) }
    let titleFirstWriter = SchemaRegistry(version: 2, entities: [noteSchema(["title": .firstWriterWins, "status": .monotone(order: Fixture.statusOrder)])])
    let statusDropped = SchemaRegistry(version: 2, entities: [noteSchema(["title": .register])])
    let noteAsDraft = SchemaRegistry(
      version: 2, entities: [EntitySchema(kind: Fixture.note, shape: .revisioned(fields: ["title": .register], marks: [], retention: .keepAll), syncClass: .general)])
    let markDropped = SchemaRegistry(
      version: 2, entities: [EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(3)), syncClass: .general)])
    let cases: [(VaultState, SchemaRegistry, String)] = [
      (note, titleFirstWriter, "field note.title holds register, which first writer wins does not extend"),
      (note, statusDropped, "field note.status is no longer declared"),
      (note, noteAsDraft, "note/k1 is record but the kind is declared revisioned"),
      (
        note, Fixture.registry(version: 9, noteFields: [:], status: ["draft"], marks: [], tag: false),
        "field note.status holds monotone [draft, review, final], which monotone [draft] does not extend"
      ),
      (draft, markDropped, "mark draft.approved is no longer declared"),
      (draft, SchemaRegistry(version: 2, entities: []), "kind draft is no longer declared"),
    ]
    for (state, registry, reason) in cases {
      var attempt = state
      #expect(throws: VaultStateError.incompatibleRegistry(reason)) { try attempt.reinterpretForeign(registry: registry) }
      #expect(attempt == state)
    }
  }

  @Test("should drop foreign data of a purged entity but keep a foreign purge")
  func shouldDropForeignOfPurgedEntity() throws {
    let key = Fixture.key("k1")
    let ref = EntityRef(kind: Fixture.note, key: key)
    let purge = Fixture.change(.purge, Fixture.note, key, clock: Fixture.clock(1))
    let foreign = [
      Fixture.change(.set, Fixture.note, key, clock: Fixture.clock(5), fields: ["pinned": true]),
      Fixture.change(.set, Fixture.note, key, clock: Fixture.clock(0), fields: ["pinned": true, "title": "t"]),
      Fixture.change(.append, Fixture.note, key, clock: Fixture.clock(2), fields: ["text": "x"]),
    ]
    let foreignPurge = Fixture.change(.purge, Fixture.note, key, clock: Fixture.clock(3), fields: ["reason": "spam"])
    for order in [[purge] + foreign + [foreignPurge], foreign + [foreignPurge, purge], [foreignPurge] + foreign.reversed() + [purge]] {
      let state = Fixture.state(order)
      #expect(state.foreign == [foreignPurge])
      #expect(state.state(of: ref) == .purged(PurgedState(clock: Fixture.clock(1))))
      #expect(Fixture.state(foreign).merging(Fixture.state([purge, foreignPurge])) == state)
    }
    var tagged = Fixture.state([Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(2), fields: ["label": 1])])
    tagged.apply(Fixture.change(.purge, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1)), registry: Fixture.v1)
    #expect(tagged.foreign.count == 1)
    #expect(tagged.foreign.first?.kind == .purge)
    try tagged.reinterpretForeign(registry: Fixture.v2)
    #expect(tagged.foreign.isEmpty)
    #expect(tagged.state(of: EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))) == .purged(PurgedState(clock: Fixture.clock(1))))
  }

  @Test("should drop foreign data of a purged entity for any order and partition")
  func shouldDropForeignOfPurgedOnRandomHistories() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let key = generator.pick(from: Fixture.noteKeys)
      let ref = EntityRef(kind: Fixture.note, key: key)
      var changes = (0..<generator.int(in: 1...12)).map { _ in
        let clock = factory.clock(&generator)
        let fields: [String: JSONValue] = generator.chance(0.5) ? ["pinned": generator.pick(from: Fixture.values)] : ["pinned": 1, "title": generator.pick(from: Fixture.values)]
        return generator.chance(0.2)
          ? Fixture.change(.append, Fixture.note, key, clock: clock, fields: fields, id: Fixture.uuid(&generator))
          : Fixture.change(.set, Fixture.note, key, clock: clock, fields: fields, id: Fixture.uuid(&generator))
      }
      let purge = Fixture.change(.purge, Fixture.note, key, clock: factory.clock(&generator), id: Fixture.uuid(&generator))
      changes.insert(purge, at: generator.int(in: 0...changes.count))
      changes += factory.changes(&generator, count: 0...10)
      let reference = Fixture.state(changes)
      try #require(reference.foreign.allSatisfy { $0.ref != ref || $0.kind == .purge })
      try #require(partitioned(changes, Fixture.v1, &generator) == reference)
      try #require(try VaultState(decodingLines: reference.encodedLines()) == reference)
      try #require(Fixture.rebuilt(reference) == reference)
    }
  }

  @Test("should let a foreign field-less purge of an undeclared kind drop the other foreign records of its entity in any order")
  func shouldAbsorbForeignOfUndeclaredPurge() throws {
    let tag = EntityRef(kind: Fixture.tag, key: Fixture.key("t1"))
    let other = EntityRef(kind: Fixture.tag, key: Fixture.key("t2"))
    let purge = Fixture.change(.purge, tag.kind, tag.key, clock: Fixture.clock(3))
    let reasoned = Fixture.change(.purge, tag.kind, tag.key, clock: Fixture.clock(4), fields: ["reason": "spam"])
    let sets = [1, 5].map { Fixture.change(.set, tag.kind, tag.key, clock: Fixture.clock($0), fields: ["label": .int($0)]) }
    let survivor = Fixture.change(.set, other.kind, other.key, clock: Fixture.clock(2), fields: ["label": 1])
    let changes = sets + [purge, reasoned, survivor]
    for order in [changes, changes.reversed(), [purge] + sets + [survivor, reasoned]] {
      let state = Fixture.state(order)
      #expect(state.foreign == sortedByBytes([purge, reasoned, survivor]))
      #expect(Fixture.state(Array(order.prefix(2))).merging(Fixture.state(Array(order.dropFirst(2)))) == state)
      #expect(try VaultState(decodingLines: state.encodedLines()) == state)
      #expect(Fixture.rebuilt(state) == state)
      var updated = state
      try updated.reinterpretForeign(registry: Fixture.v2)
      #expect(updated == Fixture.state(order, Fixture.v2))
      #expect(updated.state(of: tag) == .purged(PurgedState(clock: Fixture.clock(3))))
    }
  }

  @Test("should reject lines that keep foreign data beside a foreign field-less purge of its entity")
  func shouldRejectForeignBesideAbsorbingPurge() throws {
    let key = Fixture.key("t1")
    let purge = Fixture.change(.purge, Fixture.tag, key, clock: Fixture.clock(1))
    let set = Fixture.change(.set, Fixture.tag, key, clock: Fixture.clock(2), fields: ["label": 1])
    let foreign = sortedByBytes([purge, set]).map { record -> Data in CanonicalJSON.encode(["record": record.json, "type": "foreign"]) }
    let lines = [VaultState().encodedLines()[0]] + foreign
    let offending = foreign.firstIndex(of: CanonicalJSON.encode(["record": set.json, "type": "foreign"])).map { $0 + 1 } ?? 0
    #expect(throws: VaultStateError.malformedLine(line: offending)) { try VaultState(decodingLines: lines) }
  }

  @Test("should drop the foreign records of an undeclared kind's purged entity for any order, partition and later registry")
  func shouldAbsorbForeignOnRandomHistories() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let keys = ["t1", "t2"].map(Fixture.key)
      var changes = (0..<generator.int(in: 1...10)).map { _ in
        let clock = factory.clock(&generator)
        let key = generator.pick(from: keys)
        let id = Fixture.uuid(&generator)
        switch generator.int(in: 0...5) {
        case 0: return Fixture.change(.purge, Fixture.tag, key, clock: clock, id: id)
        case 1: return Fixture.change(.purge, Fixture.tag, key, clock: clock, fields: ["reason": generator.pick(from: Fixture.values)], id: id)
        case 2: return Fixture.change(.append, Fixture.tag, key, clock: clock, fields: ["label": generator.pick(from: Fixture.values)], id: id)
        default: return Fixture.change(.set, Fixture.tag, key, clock: clock, fields: ["label": generator.pick(from: Fixture.values)], id: id)
        }
      }
      changes += factory.changes(&generator, count: 0...10)
      let reference = Fixture.state(changes)
      try #require(reference.foreign == expectedForeign(changes, Fixture.v1))
      try #require(partitioned(changes, Fixture.v1, &generator) == reference)
      try #require(try VaultState(decodingLines: reference.encodedLines()) == reference)
      try #require(Fixture.rebuilt(reference) == reference)
      var updated = reference
      try updated.reinterpretForeign(registry: Fixture.v2)
      try #require(updated == fresh(changes, Fixture.v2, &generator))
    }
  }

  @Test("should keep opaque lines through merge, retention, reinterpretation and the line round trip")
  func shouldKeepOpaqueLines() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var a = Fixture.state(factory.changes(&generator, count: 0...10))
      var b = Fixture.state(factory.changes(&generator, count: 0...10))
      let lines = (0..<generator.int(in: 1...5)).map { _ in generator.opaqueLine() }
      for line in lines {
        if generator.chance(0.5) { a.keepOpaque(line) } else { b.keepOpaque(line) }
      }
      var merged = a.merging(b).retained(registry: Fixture.v1)
      try merged.reinterpretForeign(registry: Fixture.v2)
      let expected = Set(lines).sorted { $0.lexicographicallyPrecedes($1) }
      try #require(merged.opaqueLines == expected)
      try #require(try VaultState(decodingLines: merged.encodedLines()).opaqueLines == expected)
      var reinterpreted = merged
      try reinterpreted.reinterpretForeign(registry: Fixture.v2)
      try #require(reinterpreted.opaqueLines == expected)
    }
  }

  @Test("should move a monotone field onto an extended order when reinterpreting")
  func shouldRestampExtendedMonotoneOrder() throws {
    let key = Fixture.key("k1")
    var state = Fixture.state([
      Fixture.change(.set, Fixture.note, key, clock: Fixture.clock(1), fields: ["status": "final"]),
      Fixture.change(.set, Fixture.note, key, clock: Fixture.clock(2), fields: ["status": "archived"]),
    ])
    try state.reinterpretForeign(registry: Fixture.v2)
    guard case .record(let note) = state.state(of: EntityRef(kind: Fixture.note, key: key)) else { throw ForeignTestFailure.notARecord }
    #expect(note[field: "status"] == FieldState(value: "archived", clock: Fixture.clock(2), rule: .monotone(order: Fixture.extendedStatusOrder)))
  }
}

private enum ForeignTestFailure: Error {
  case notARecord
}
