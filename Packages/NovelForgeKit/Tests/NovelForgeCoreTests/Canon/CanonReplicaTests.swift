import Foundation
import GRDB
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

/// Everything the winning canon's review feeds, read from one replica.
private struct CanonSummary: Equatable, CustomStringConvertible {
  var appearances: Set<String>
  var states: Set<StateView>
  var relationships: Set<String>
  var promises: [String: PromiseView]
  var milestones: [String: MilestoneSnapshot]
  var knowledge: Set<LedgerView>

  static func read(_ store: VaultStore) async throws -> CanonSummary {
    CanonSummary(
      appearances: try await CanonTables.appearances(novel, in: store), states: try await CanonTables.states(novel, in: store),
      relationships: try await CanonTables.relationships(novel, in: store), promises: try await CanonTables.promises(novel, in: store),
      milestones: try await PlanWorldTables.milestones(novel, in: store), knowledge: try await ChapterTables.knowledge(novel, in: store))
  }

  var description: String { "\(appearances.sorted()) \(states) \(relationships.sorted()) \(promises) \(milestones) \(knowledge)" }
}

private let first = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c1")
private let second = SchemaFixture.uuid("6f0c4d1e-0000-4000-8000-0000000000c2")

/// Two devices finalize chapter 1 from different answers to its review.
private let reviews: [UUID: (review: CanonReview, knowledge: [KnowledgeReveal], expected: CanonSummary)] = [
  first: (
    review(
      [
        Kept.appearance("mira"), Kept.state("mira", location: "the pier"), Kept.relationship("mira", "tobin", "ally"), Kept.thread("ledger", .closed),
        Kept.milestone("fall"), Kept.knowledge("tobin", "heir"),
      ], id: first),
    [KnowledgeReveal(entityKey: "mira", factKey: "heir")],
    CanonSummary(
      appearances: ["mira@1"], states: [StateView("mira", location: "the pier", chapter: 1)], relationships: ["mira→tobin:ally@1 -"],
      promises: ["thread:ledger": PromiseView("ledger", "closed", closed: 1, text: "Old.", advanced: 1)],
      milestones: ["rise": MilestoneSnapshot("reached", planned: 1, reached: 1), "fall": MilestoneSnapshot("reached", planned: 1, reached: 1)],
      knowledge: [LedgerView("heir", "mira", 1, .brief, .committed), LedgerView("heir", "tobin", 1, .generated, .committed)])
  ),
  second: (
    review([Kept.appearance("tobin"), Kept.state("mira", location: "the tower"), Kept.thread("ledger", .open, summary: "Lost again.")], unreached: ["rise"], id: second),
    [],
    CanonSummary(
      appearances: ["tobin@1"], states: [StateView("mira", location: "the tower", chapter: 1)], relationships: [],
      promises: ["thread:ledger": PromiseView("ledger", "open", text: "Lost again.", advanced: 1)],
      milestones: ["rise": MilestoneSnapshot("open"), "fall": MilestoneSnapshot("open")], knowledge: [])
  ),
]

private func expectRebuilt(_ reconciler: NovelForgeReconciler, _ store: VaultStore) async throws {
  let comparison = try await Projection.compare(reconciler, in: store)
  guard comparison.incremental == comparison.rebuilt else { throw ProjectionPropertyFailure.notARebuild(comparison) }
}

@Suite("Canon review across devices", TestTimeLimit.standard)
struct CanonReplicaTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldApplyTheItemsOfTheCanonThatWonOnEveryReplica(order: CausalReplicaOrder) async throws {
    let reconciler = try Projection.reconciler()
    try await forAllConcurrently(iterations: ProjectionProperty.iterations(full: 12), seed: order == .causal ? 0x627A : 0x627B) { generator in
      let replicas = try await CausalReplicas(
        CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, order: order, reconciler: { _ in reconciler }, seed: generator.next()))
      try await replicas.write(0) { transaction in
        for key in ["mira", "tobin"] { try ChapterWrites.entity(novel: novel, key, in: &transaction) }
        for key in ["rise", "fall"] { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
        try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
        _ = try ThreadRecord(novel: novel, thread: "ledger", summary: "Old.").create(in: &transaction)
      }
      try await replicas.settle()
      let finalizing = generator.shuffled([1, 2])
      for (index, id) in zip(finalizing, [first, second]) {
        await replicas.advanceClock(of: index, by: .milliseconds(generator.int(in: 1...40)))
        let (review, knowledge, _) = try #require(reviews[id])
        try await replicas.write(index) { transaction in
          try CanonWrites.finalize(novel: novel, chapter: 1, review: review, knowledge: knowledge, contract: contract(claims: ["rise"]), in: &transaction)
        }
        while generator.chance(0.5), try await replicas.step(using: &generator) {}
      }
      try await replicas.settle()

      var winner: UUID?
      for index in 0..<3 {
        let store = await replicas.store(index)
        let canon = try await store.read { transaction in
          try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record.canon
        }
        let id = try #require(canon?.review?.id)
        if let winner { #expect(id == winner) }
        winner = id
        let summary = try await CanonSummary.read(store)
        let expected = try #require(reviews[id]).expected
        guard summary == expected else { throw ProjectionPropertyFailure.oracle("replica \(index): \(summary) is not \(expected)") }
        try await expectRebuilt(reconciler, store)
      }
    }
  }
}

private let entityKeys = ["mira", "tobin"]

private func keptPool(_ generator: inout SeededGenerator) -> ProposedChange {
  let entity = generator.pick(from: entityKeys + ["ghost"])
  return switch generator.int(in: 0...8) {
  case 0: Kept.entity(entity)
  case 1: Kept.appearance(entity)
  case 2: Kept.state(entity, location: generator.pick(from: ["pier", "tower"]), conditions: generator.chance(0.5) ? ["tired"] : nil)
  case 3: Kept.relationship(entity, generator.pick(from: entityKeys), "ally", note: generator.chance(0.5) ? "wary" : nil)
  case 4: Kept.thread("ledger", generator.pick(from: ThreadStatus.allCases), summary: generator.chance(0.5) ? "S." : nil, open: generator.chance(0.3) ? true : nil)
  case 5: Kept.mystery("who", generator.pick(from: [MysteryStatus.open, .resolved]), question: generator.chance(0.5) ? "Who?" : nil, truth: generator.chance(0.3) ? "heir" : nil)
  case 6: Kept.knowledge(entity, "heir")
  case 7: Kept.milestone("rise", reached: generator.chance(0.7))
  default: Kept.milestone("fall")
  }
}

enum CanonOperations {
  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "finalize a reviewed chapter", weight: 4) { generator, universe in
      let (novel, chapter) = (universe.novel(&generator), universe.chapter(&generator))
      let kept = (0..<generator.int(in: 0...4)).map { _ in keptPool(&generator) }
      let unreached = generator.chance(0.3) ? ["rise"] : []
      let knowledge: [KnowledgeReveal]? =
        switch generator.int(in: 0...2) {
        case 0: nil
        case 1: []
        default: [KnowledgeReveal(entityKey: generator.pick(from: entityKeys), factKey: "heir")]
        }
      let claims = generator.chance(0.5) ? ["rise"] : []
      let reviewed = generator.chance(0.8) ? review(kept, unreached: unreached, id: generator.uuid()) : nil
      return { transaction in
        try CanonWrites.finalize(
          novel: novel, chapter: chapter, review: reviewed, knowledge: knowledge, contract: contract(learns: [Learn("mira", "heir")], claims: claims), in: &transaction)
      }
    },
    ProjectionOperation(name: "finalize with an unreadable member", weight: 1) { generator, universe in
      let (novel, chapter, member) = (universe.novel(&generator), universe.chapter(&generator), generator.pick(from: [FinalChapterCanonMember.review, .knowledge]))
      return { transaction in try CanonWrites.finalize(novel: novel, chapter: chapter, unreadable: member, in: &transaction) }
    },
    ProjectionOperation(name: "create or restore entity", weight: 3) { generator, universe in
      let (novel, key) = (universe.novel(&generator), generator.pick(from: entityKeys + ["ghost"]))
      return { transaction in try CanonWrites.entity(novel: novel, key, in: &transaction) }
    },
    ProjectionOperation(name: "remove entity", weight: 1) { generator, universe in
      let (novel, key) = (universe.novel(&generator), generator.pick(from: entityKeys + ["ghost"]))
      return { transaction in try CanonWrites.removeEntity(novel: novel, key, in: &transaction) }
    },
    ProjectionOperation(name: "create secret or milestone", weight: 2) { generator, universe in
      let (novel, secret) = (universe.novel(&generator), generator.chance(0.5))
      return { transaction in
        if secret {
          guard case .absent = try SecretRecord.read(SecretRecord.ref(novel: novel, secret: "heir"), in: transaction) else { return }
          try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
        } else {
          for key in ["rise", "fall"] {
            guard case .absent = try MilestoneRecord.read(MilestoneRecord.ref(novel: novel, milestone: key), in: transaction) else { continue }
            try PlanWorldWrites.milestone(novel: novel, key, in: &transaction)
          }
        }
      }
    },
    ProjectionOperation(name: "write a promise", weight: 2) { generator, universe in
      let (novel, status, dormant) = (universe.novel(&generator), generator.pick(from: ThreadStatus.allCases), generator.chance(0.3))
      let creates = generator.chance(0.4)
      return { transaction in
        let ref = ThreadRecord.ref(novel: novel, thread: "ledger")
        switch try ThreadRecord.read(ref, in: transaction) {
        case .absent:
          _ = try ThreadRecord(novel: novel, thread: "ledger", summary: "Old.", status: ThreadProgress(state: .known(status)), dormant: dormant).create(in: &transaction)
        case .readable(let entry) where !entry.isRemoved:
          if creates {
            _ = try ThreadRecord.remove(novel: novel, thread: "ledger", in: &transaction)
          } else {
            var edit = ThreadEdit()
            edit.status = .set(ThreadProgress(state: .known(status), chapter: status == .open ? nil : 2))
            edit.dormant = .set(dormant)
            _ = try ThreadRecord.edit(novel: novel, thread: "ledger", edit, in: &transaction)
          }
        default:
          return
        }
      }
    },
    ProjectionOperation(name: "reveal or retract by hand", weight: 1) { generator, universe in
      let (novel, entity, retracts) = (universe.novel(&generator), generator.pick(from: entityKeys), generator.chance(0.4))
      return { transaction in
        if retracts { return try ChapterWrites.retract(novel: novel, fact: "heir", entity: entity, in: &transaction) }
        try ChapterWrites.reveal(novel: novel, fact: "heir", entity: entity, chapter: 3, in: &transaction)
      }
    },
  ]
}

/// The milestones each novel's final chapters reached, read from the canons as stored, against the derived states.
private func milestoneOracle(_ reconciler: NovelForgeReconciler, _ store: VaultStore, _ universe: ProjectionUniverse) async throws {
  for novel in universe.novels {
    let expected = try await store.read { transaction in
      let finals = try FinalChapterRecord.listing(in: transaction).entries.map(\.record).filter { $0.novel == novel }.sorted { $0.chapter < $1.chapter }
      var reached = [String: Int]()
      for final in finals {
        let canon = final.canon
        var keys = canon.contract.claimedMilestones
        if let review = canon.review {
          keys = keys.filter { !review.unreached.contains($0) }
          for item in review.kept { if case .milestone(let milestone)? = ProposedChange(json: .object(item)), milestone.reached { keys.append(milestone.milestoneKey) } }
        } else if canon.unrecognised[FinalChapterCanonMember.review.rawValue] != nil {
          keys = []
        }
        for key in keys where reached[key] == nil { reached[key] = final.chapter }
      }
      let live = try MilestoneRecord.listing(novel: novel, in: transaction).live.map(\.milestone)
      return Dictionary(uniqueKeysWithValues: live.map { ($0, reached[$0]) })
    }
    let projected = Dictionary(uniqueKeysWithValues: try await PlanWorldTables.milestones(novel, in: store).map { ($0.key, $0.value.reached) })
    guard projected == expected else { throw ProjectionPropertyFailure.oracle("milestones of \(novel): \(projected) is not \(expected)") }
  }
}

@Suite("Canon projection property", TestTimeLimit.property)
struct CanonPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldKeepEveryCanonDerivedTableEqualToARebuildAndConvergeOnEveryReplica(order: CausalReplicaOrder) async throws {
    let property = ProjectionProperty(
      operations: ProjectionOperations.novels + ProjectionOperations.chapters + ProjectionOperations.canon, iterations: 10, steps: 32, settled: milestoneOracle)
    try await property.check(order: order, seed: order == .causal ? 0x627C : 0x627D)
  }
}
