import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let noteRef = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let draftRef = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
private let messageRef = EntityRef(kind: Fixture.message, key: Fixture.key("m1"))

private func noteSet(_ clock: HLCTimestamp, _ fields: [String: JSONValue]) -> ChangeRecord {
  Fixture.change(.set, Fixture.note, noteRef.key, clock: clock, fields: fields)
}

private func item(_ body: JSONValue, _ created: Int64) -> RevisionItem {
  RevisionItem(parent: nil, body: body, created: Fixture.clock(created), generation: created)
}

private func record(_ state: VaultState, _ ref: EntityRef = noteRef) -> RecordState? {
  guard case .record(let record) = state.state(of: ref) else { return nil }
  return record
}

private func revisioned(_ state: VaultState) -> RevisionedState? {
  guard case .revisioned(let revisioned) = state.state(of: draftRef) else { return nil }
  return revisioned
}

private func everyOrder(_ changes: [ChangeRecord]) -> [VaultState] {
  guard changes.count > 1 else { return [Fixture.state(changes)] }
  return changes.indices.flatMap { index in
    var rest = changes
    let first = rest.remove(at: index)
    return everyOrder(rest).map { tail in Fixture.state([first]).merging(tail) }
  }
}

@Suite("Merge rules")
struct MergeRuleTests {
  @Test("should let the higher clock win a register in either order")
  func shouldResolveRegisterByClock() {
    let changes = [noteSet(Fixture.clock(2), ["title": "new"]), noteSet(Fixture.clock(1), ["title": "old"])]
    for state in everyOrder(changes) { #expect(record(state)?[field: "title"]?.value == "new") }
  }

  @Test("should break an equal register clock by the greater canonical bytes")
  func shouldBreakRegisterTieByBytes() {
    let changes = [noteSet(Fixture.clock(1), ["title": "a"]), noteSet(Fixture.clock(1), ["title": "b"]), noteSet(Fixture.clock(1), ["title": "B"])]
    for state in everyOrder(changes) { #expect(record(state)?[field: "title"]?.value == "b") }
  }

  @Test("should merge different fields independently")
  func shouldMergeFieldsIndependently() {
    let changes = [noteSet(Fixture.clock(2), ["title": "new"]), noteSet(Fixture.clock(1), ["title": "old", "origin": "first"])]
    for state in everyOrder(changes) {
      #expect(record(state)?[field: "title"]?.value == "new")
      #expect(record(state)?[field: "origin"]?.value == "first")
    }
  }

  @Test("should let the later monotone value win whatever its clock")
  func shouldResolveMonotoneByRank() {
    let changes = [noteSet(Fixture.clock(1), ["status": "final"]), noteSet(Fixture.clock(3), ["status": "review"]), noteSet(Fixture.clock(2), ["status": "draft"])]
    for state in everyOrder(changes) {
      #expect(record(state)?[field: "status"]?.value == "final")
      #expect(record(state)?[field: "status"]?.clock == Fixture.clock(1))
    }
  }

  @Test("should keep the higher clock for an equal monotone value")
  func shouldKeepHigherClockForEqualRank() {
    let changes = [noteSet(Fixture.clock(1), ["status": "review"]), noteSet(Fixture.clock(4), ["status": "review"])]
    for state in everyOrder(changes) { #expect(record(state)?[field: "status"]?.clock == Fixture.clock(4)) }
  }

  @Test("should let the lower clock win a first-writer field")
  func shouldResolveFirstWriterByLowerClock() {
    let changes = [noteSet(Fixture.clock(2), ["origin": "second"]), noteSet(Fixture.clock(1), ["origin": "first"])]
    for state in everyOrder(changes) { #expect(record(state)?[field: "origin"]?.value == "first") }
  }

  @Test("should break an equal first-writer clock by the smaller canonical bytes")
  func shouldBreakFirstWriterTieByBytes() {
    let changes = [noteSet(Fixture.clock(1), ["origin": "b"]), noteSet(Fixture.clock(1), ["origin": "a"])]
    for state in everyOrder(changes) { #expect(record(state)?[field: "origin"]?.value == "a") }
  }

  @Test("should keep the lowest purge clock and drop every other change before or after it")
  func shouldMakePurgeAbsorbing() {
    let changes = [
      noteSet(Fixture.clock(1), ["title": "a"]), Fixture.change(.purge, Fixture.note, noteRef.key, clock: Fixture.clock(3)),
      noteSet(Fixture.clock(5), ["title": "b"]), Fixture.change(.purge, Fixture.note, noteRef.key, clock: Fixture.clock(2)),
    ]
    for state in everyOrder(changes) { #expect(state.state(of: noteRef) == .purged(PurgedState(clock: Fixture.clock(2)))) }
  }

  @Test("should absorb changes that arrive before and after a purge on random histories")
  func shouldAbsorbAroundPurgeOnRandomHistories() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var history = (0..<generator.int(in: 0...12)).map { _ in factory.noteSet(&generator, key: noteRef.key) }
      let purges = (0..<generator.int(in: 1...3)).map { _ in Fixture.change(.purge, Fixture.note, noteRef.key, clock: factory.clock(&generator)) }
      for purge in purges { history.insert(purge, at: generator.int(in: 0...history.count)) }
      let expected = EntityState.purged(PurgedState(clock: try #require(purges.map(\.clock).min())))
      try #require(Fixture.state(history).state(of: noteRef) == expected)
      try #require(Fixture.state(generator.withDuplicates(history)).state(of: noteRef) == expected)
      let later = Fixture.state((0..<generator.int(in: 1...6)).map { _ in factory.noteSet(&generator, key: noteRef.key) })
      try #require(Fixture.state(history).merging(later).state(of: noteRef) == expected)
      try #require(later.merging(Fixture.state(history)).state(of: noteRef) == expected)
    }
  }

  @Test("should resolve exact clock collisions with different values the same way in every order")
  func shouldResolveCollisionsInEveryOrder() throws {
    try forAll(iterations: 300) { generator in
      let clock = Fixture.clock(Int64(generator.int(in: 0...3)), replica: generator.int(in: 0...2))
      let collisions = (0..<generator.int(in: 2...6)).map { _ in
        let status = JSONValue.string(generator.pick(from: Fixture.statusOrder))
        return noteSet(clock, ["title": generator.pick(from: Fixture.values), "origin": generator.pick(from: Fixture.values), "status": status])
      }
      let reference = Fixture.state(collisions)
      for _ in 0..<4 { try #require(Fixture.state(generator.withDuplicates(collisions)).digest == reference.digest) }
      let titles = collisions.compactMap { $0.fields["title"] }.map(CanonicalJSON.encode)
      let origins = collisions.compactMap { $0.fields["origin"] }.map(CanonicalJSON.encode)
      let resolved = try #require(record(reference))
      try #require(CanonicalJSON.encode(try #require(resolved[field: "title"]?.value)) == titles.max { $0.lexicographicallyPrecedes($1) })
      try #require(CanonicalJSON.encode(try #require(resolved[field: "origin"]?.value)) == origins.min { $0.lexicographicallyPrecedes($1) })
    }
  }

  @Test("should let the lower clock win an appended item, ties by smaller bytes")
  func shouldResolveAppendedDuplicates() {
    let first = Fixture.change(.append, Fixture.message, messageRef.key, clock: Fixture.clock(1), fields: ["text": "z"])
    let later = Fixture.change(.append, Fixture.message, messageRef.key, clock: Fixture.clock(2), fields: ["text": "a"])
    let tie = Fixture.change(.append, Fixture.message, messageRef.key, clock: Fixture.clock(1), fields: ["text": "y"])
    for state in everyOrder([first, later, tie]) { #expect(state.state(of: messageRef) == .appended(AppendedState(item: ["text": "y"], clock: Fixture.clock(1)))) }
  }

  @Test("should union revisions and treat the head and marks as registers written by revise records")
  func shouldUnionRevisionsAndRegisterPointers() {
    let (first, second, third) = (item("one", 1), item("two", 3), item("three", 4))
    let changes = [
      Fixture.revise(first, clock: Fixture.clock(1)), Fixture.revise(second, clock: Fixture.clock(3)), Fixture.revise(third, clock: Fixture.clock(4), head: false),
      Fixture.revise(first, clock: Fixture.clock(2), head: false, marks: ["approved"]),
      Fixture.change(.set, Fixture.draft, draftRef.key, clock: Fixture.clock(9), fields: ["title": "t", "head": .string(third.id)]),
    ]
    for state in everyOrder(changes) {
      let draft = revisioned(state)
      #expect(draft?.revisions.keys.sorted() == [first.id, second.id, third.id].map(ExactString.init(_:)).sorted())
      #expect(draft?.head == FieldState(value: .string(second.id), clock: Fixture.clock(3), rule: .register))
      #expect(draft?[mark: "approved"] == FieldState(value: .string(first.id), clock: Fixture.clock(2), rule: .register))
      #expect(draft?[field: "title"]?.value == "t")
      #expect(state.foreign.map(\.fields) == [["head": .string(third.id)]])
    }
  }

  @Test("should store a re-asserted revision as the identical item with its original created clock")
  func shouldKeepReassertedItemIdentical() {
    let original = item("one", 1)
    let changes = [Fixture.revise(original, clock: Fixture.clock(1), head: false), Fixture.revise(original, clock: Fixture.clock(7))]
    for state in everyOrder(changes) {
      #expect(revisioned(state)?.revisions[ExactString(original.id)] == original)
      #expect(revisioned(state)?.revisions.count == 1)
      #expect(revisioned(state)?.head?.clock == Fixture.clock(7))
    }
  }

  @Test("should join a monotone field under the extended order when states come from successive registries")
  func shouldJoinUnderExtendedOrder() throws {
    let older = Fixture.state([noteSet(Fixture.clock(1), ["status": "final"])], Fixture.v1)
    let newer = Fixture.state([noteSet(Fixture.clock(2), ["status": "archived"])], Fixture.v2)
    let expected = FieldState(value: "archived", clock: Fixture.clock(2), rule: .monotone(order: Fixture.extendedStatusOrder))
    for merged in [older.merging(newer), newer.merging(older)] {
      #expect(record(merged)?[field: "status"] == expected)
      var reinterpreted = merged
      try reinterpreted.reinterpretForeign(registry: Fixture.v2)
      #expect(reinterpreted == Fixture.state([noteSet(Fixture.clock(1), ["status": "final"]), noteSet(Fixture.clock(2), ["status": "archived"])], Fixture.v2))
    }
    let higherOld = Fixture.state([noteSet(Fixture.clock(9), ["status": "final"])], Fixture.v1)
    let lowerNew = Fixture.state([noteSet(Fixture.clock(2), ["status": "review"])], Fixture.v2)
    for merged in [higherOld.merging(lowerNew), lowerNew.merging(higherOld)] {
      #expect(record(merged)?[field: "status"] == FieldState(value: "final", clock: Fixture.clock(9), rule: .monotone(order: Fixture.extendedStatusOrder)))
    }
  }

  @Test("should make apply equal to merging the state of that change alone")
  func shouldMakeApplyEqualToMerge() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let base = Fixture.state(factory.changes(&generator, count: 0...20))
      let change = factory.change(&generator)
      var applied = base
      applied.apply(change, registry: Fixture.v1)
      try #require(applied == base.merging(Fixture.state([change])))
    }
  }
}
