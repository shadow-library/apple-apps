import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let draftRef = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

private let aYearAhead: Int64 = 31_536_000_000

private func item(_ body: JSONValue, _ generation: Int64, created: Int64? = nil, parent: String? = nil) -> RevisionItem {
  RevisionItem(parent: parent, body: body, created: Fixture.clock(created ?? generation), generation: generation)
}

private func revisioned(_ state: VaultState) -> RevisionedState? {
  guard case .revisioned(let draft) = state.state(of: draftRef) else { return nil }
  return draft
}

private func revisionIDs(_ state: VaultState) -> Set<String> {
  guard case .revisioned(let draft) = state.state(of: draftRef) else { return [] }
  return Set(draft.revisions.keys.map(\.value))
}

private func g(_ state: VaultState) -> VaultState {
  state.retained(registry: Fixture.v1)
}

private func namedRevisionsArePresent(_ state: VaultState) -> Bool {
  state.refs.allSatisfy { ref in
    guard case .revisioned(let draft) = state.state(of: ref) else { return true }
    return draft.namedRevisions.isSubset(of: draft.revisions.keys)
  }
}

@Suite("Retention")
struct RetentionTests {
  @Test("should keep the newest revisions by generation plus the head and every mark")
  func shouldKeepNewestHeadAndMarks() {
    let items = (1...6).map { item(.string("body \($0)"), Int64($0)) } + [item("late twin", 6)]
    let changes =
      items.map { Fixture.revise($0, clock: $0.created, head: false) } + [
        Fixture.revise(items[1], clock: Fixture.clock(8)), Fixture.revise(items[0], clock: Fixture.clock(9), head: false, marks: ["approved"]),
      ]
    let expected = Set([items[0], items[1], items[4], items[5], items[6]].map(\.id))
    #expect(revisionIDs(g(Fixture.state(changes))) == expected)
  }

  @Test("should not give a re-asserted old revision a newest slot")
  func shouldRankByCreatedNotDeliveryClock() {
    let items = (1...4).map { item(.string("body \($0)"), Int64($0)) }
    let changes = items.map { Fixture.revise($0, clock: $0.created, head: $0 == items[3]) } + [Fixture.revise(items[0], clock: Fixture.clock(20), head: false)]
    #expect(revisionIDs(g(Fixture.state(changes))) == Set(items[1...].map(\.id)))
  }

  @Test("should prune a far-future created clock with a low generation before an older created clock with a higher generation")
  func shouldIgnoreCreatedWhenRanking() {
    let skewed = item("skewed", 1, created: aYearAhead)
    let items = [item("two", 2), item("three", 3), item("four", 4)]
    let changes = [Fixture.revise(skewed, clock: skewed.created, head: false)] + items.map { Fixture.revise($0, clock: $0.created, head: $0 == items[2]) }
    #expect(revisionIDs(g(Fixture.state(changes))) == Set(items.map(\.id)))
  }

  @Test("should keep the newest of both branches when two writers extend the same generation")
  func shouldKeepNewestOfBothBranches() throws {
    let root = item("root", 0)
    func branch(_ name: String) -> [RevisionItem] {
      (1...5).reduce(into: [RevisionItem]()) { chain, generation in
        chain.append(item(.string("\(name) \(generation)"), Int64(generation), parent: chain.last?.id ?? root.id))
      }
    }
    let (left, right) = (branch("left"), branch("right"))
    let changes = [Fixture.revise(root, clock: Fixture.clock(0))] + (left + right).map { Fixture.revise($0, clock: $0.created, head: false) }
    let thirdSlot = [left[3], right[3]].max { ExactString($0.id) < ExactString($1.id) }
    let expected = Set([root.id, left[4].id, right[4].id, try #require(thirdSlot).id])
    #expect(revisionIDs(g(Fixture.state(changes))) == expected)
    #expect(revisionIDs(g(Fixture.state(changes.reversed()))) == expected)
  }

  @Test("should give the next generation as one past the highest held, saturating at the maximum")
  func shouldComputeNextGeneration() throws {
    #expect(RevisionedState(fields: [:], head: nil, marks: [:], revisions: [:]).nextGeneration == 0)
    let state = Fixture.state([Fixture.revise(item("a", 3), clock: Fixture.clock(1)), Fixture.revise(item("b", 1), clock: Fixture.clock(2), head: false)])
    #expect(revisioned(state)?.nextGeneration == 4)
    let saturated = Fixture.state([Fixture.revise(item("max", Int64.max, created: 1), clock: Fixture.clock(1))])
    #expect(revisioned(saturated)?.nextGeneration == Int64.max)
    #expect(revisionIDs(g(saturated)).count == 1)
  }

  @Test("should return a pruned revision intact when another replica re-asserts it, in any exchange order")
  func shouldRecoverPrunedRevisionOnReassertion() throws {
    let old = item("old", 0, created: aYearAhead)
    let newer = (1...4).map { item(.string("newer \($0)"), Int64($0)) }
    let written = Fixture.revise(old, clock: Fixture.clock(1))
    let replicaB = Fixture.state([written] + newer.map { Fixture.revise($0, clock: $0.created) })
    try #require(!revisionIDs(g(replicaB)).contains(old.id))
    let replicaA = Fixture.state([
      written, Fixture.revise(old, clock: Fixture.clock(10)), Fixture.revise(old, clock: Fixture.clock(11), head: false, marks: ["approved"]),
    ])
    let outcomes = [
      g(replicaA.merging(g(replicaB))), g(g(replicaB).merging(replicaA)), g(g(replicaA).merging(g(replicaB))), g(replicaB.merging(replicaA)),
      g(g(g(replicaB).merging(g(replicaA))).merging(replicaB)),
    ]
    for outcome in outcomes {
      #expect(outcome.digest == outcomes[0].digest)
      guard case .revisioned(let draft) = outcome.state(of: draftRef) else {
        Issue.record("draft is not revisioned")
        continue
      }
      #expect(draft.revisions[ExactString(old.id)] == old)
      #expect(draft.revisions[ExactString(old.id)]?.created == Fixture.clock(aYearAhead))
      #expect(draft.revisions[ExactString(old.id)]?.generation == 0)
      #expect(draft.headRevision == old.id)
      #expect(draft[mark: "approved"]?.value == .string(old.id))
    }
  }

  @Test("should commute with merge when two registries disagree on the shape of a kind")
  func shouldCommuteAcrossShapeDisagreement() {
    let revisionedDraft = SchemaRegistry(
      version: 1, entities: [EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: [:], marks: [], retention: .keepNewest(1)), syncClass: .general)])
    let recordDraft = SchemaRegistry(version: 1, entities: [EntitySchema(kind: Fixture.draft, shape: .record(fields: ["title": .register]), syncClass: .general)])
    let a = Fixture.state([Fixture.revise(item("only", 0), clock: Fixture.clock(1), head: false)], revisionedDraft)
    let b = Fixture.state([Fixture.change(.set, Fixture.draft, draftRef.key, clock: Fixture.clock(2), fields: ["title": "t"])], recordDraft)
    let g = { (state: VaultState) in state.retained(registry: revisionedDraft) }
    for (first, second) in [(a, b), (b, a)] {
      #expect(g(first.merging(second)) == g(g(first).merging(g(second))))
      #expect(g(first.merging(second)).refs == [draftRef])
      #expect(revisionIDs(g(first.merging(second))) == [item("only", 0).id])
    }
  }

  @Test("should leave other shapes, purged entities and keep-all entities unchanged")
  func shouldLeaveOtherEntitiesUnchanged() throws {
    let keepAll = SchemaRegistry(
      version: 1, entities: [EntitySchema(kind: Fixture.draft, shape: .revisioned(fields: ["title": .register], marks: ["approved"], retention: .keepAll), syncClass: .general)])
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let state = Fixture.state(factory.changes(&generator))
      let retained = g(state)
      try #require(state.retained(registry: keepAll) == state)
      try #require(retained.refs == state.refs)
      try #require(retained.foreign == state.foreign)
      for ref in state.refs where ![Fixture.draft, Fixture.outline].contains(ref.kind) { try #require(retained.state(of: ref) == state.state(of: ref)) }
      for ref in state.refs {
        guard case .purged = state.state(of: ref) else { continue }
        try #require(retained.state(of: ref) == state.state(of: ref))
      }
    }
  }

  @Test("should commute with merge and be idempotent for arbitrary records and partitions")
  func shouldCommuteWithMerge() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      let parts = generator.split(factory.changes(&generator, count: 1...60), into: 2).map { Fixture.state(generator.shuffled($0)) }
      let a = generator.chance(0.3) ? g(parts[0]) : parts[0]
      let b = generator.chance(0.3) ? g(parts[1]) : parts[1]
      try #require(g(a.merging(b)) == g(g(a).merging(g(b))))
      try #require(g(a.merging(b)).digest == g(g(a).merging(g(b))).digest)
      try #require(g(g(a)) == g(a))
      try #require(g(g(a.merging(b))) == g(a.merging(b)))
    }
  }

  @Test("should keep every revision named by a winning head or mark after any apply, merge and retain")
  func shouldKeepNamedRevisionsPresent() throws {
    try forAll(iterations: 300) { generator in
      var factory = ChangeFactory()
      var states = [VaultState(), VaultState(), VaultState()]
      for _ in 0..<generator.int(in: 10...60) {
        let target = generator.int(in: 0...2)
        switch generator.int(in: 0...5) {
        case 0: states[target] = states[target].merging(states[generator.int(in: 0...2)])
        case 1: states[target] = g(states[target])
        default: states[target].apply(factory.change(&generator), registry: Fixture.v1)
        }
        try #require(namedRevisionsArePresent(states[target]))
      }
    }
  }
}
