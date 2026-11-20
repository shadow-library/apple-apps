import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private struct ReconcileFixture: Decodable {
  struct Volume: Decodable {
    let volume: String
    let ordinal: Int
  }

  struct Term: Decodable {
    let milestone: String?
    let volume: String?
    let chapter: Int?
    let ending: Bool?

    var json: JSONValue {
      if let milestone { return PlanWorldTerm.milestone(milestone).json }
      if let volume { return PlanWorldTerm.volume(volume).json }
      if let chapter { return PlanWorldTerm.chapter(chapter).json }
      return PlanWorldTerm.ending.json
    }
  }

  struct Fact: Decodable {
    let fact: String
    let revealChapter: Int?
    let unlock: [Term]?
    let source: String
  }

  struct Learned: Decodable {
    let entity: String
    let fact: String
  }

  struct Plan: Decodable {
    let chapter: Int
    let volume: String?
    let ending: Bool
    let claims: [String]
    let pov: [String]
    let learns: [Learned]

    var contract: ChapterContract {
      NovelForgeCoreTests.contract(pov: pov, learns: learns.map { Learn($0.entity, $0.fact) }, claims: claims, ending: ending)
    }
  }

  struct Reason: Decodable {
    let chapter: Int
    let reason: String?
  }

  struct Milestone: Decodable {
    let milestone: String
    let state: String
    let plannedChapter: Int?
    let reachedChapter: Int?
  }

  struct Expected: Decodable {
    let reasons: [Reason]
    let milestones: [Milestone]
  }

  struct Case: Decodable {
    let volumes: [Volume]
    let milestones: [String]
    let facts: [Fact]
    let plans: [Plan]
    let finals: Int
    let expected: Expected
  }

  let cases: [Case]
}

private func write(_ fixture: ReconcileFixture.Case, novel: UUID, in transaction: inout WriteTransaction) throws {
  for volume in fixture.volumes { try PlanWorldWrites.volume(novel: novel, volume.volume, ordinal: volume.ordinal, in: &transaction) }
  for milestone in fixture.milestones { try PlanWorldWrites.milestone(novel: novel, milestone, in: &transaction) }
  for fact in fixture.facts {
    guard let source = FactSource(rawValue: fact.source) else { throw ProjectionPropertyFailure.oracle("unknown source \(fact.source)") }
    let unlock = fact.unlock.map { JSONValue.object(["all": .array($0.map(\.json))]) }
    try PlanWorldWrites.secret(novel: novel, fact.fact, revealChapter: fact.revealChapter, unlock: unlock, source: source, in: &transaction)
  }
  for plan in fixture.plans { try PlanWorldWrites.putPlan(novel: novel, chapter: plan.chapter, planContent(volume: plan.volume, plan.contract), in: &transaction) }
  for chapter in stride(from: 1, through: fixture.finals, by: 1) {
    let plan = fixture.plans.first { $0.chapter == chapter }
    try PlanWorldWrites.finalize(novel: novel, chapter: chapter, volume: plan?.volume, plan?.contract ?? ChapterContract(), in: &transaction)
  }
}

@Suite("Plan world parity with the reference", TestTimeLimit.standard)
struct PlanWorldParityTests {
  @Test(arguments: 0..<4)
  func shouldMatchReconcilePlanStateOnEveryReferenceCase(shard: Int) async throws {
    let fixture = try ReferenceFixture.decode(ReconcileFixture.self, from: "plan-world/reconcile.json")
    #expect(fixture.cases.count == 240)
    let store = try Projection.store(try Projection.reconciler(ProjectionDerivations.all + PlanWorldDerivations.all))
    let cases = fixture.cases.enumerated().filter { $0.offset % 4 == shard }
    let novels = cases.map { _ in UUID() }
    _ = try await Projection.write(store) { transaction in
      for (fixture, novel) in zip(cases, novels) { try write(fixture.element, novel: novel, in: &transaction) }
    }
    for ((index, fixture), novel) in zip(cases, novels) {
      let expectedVerdicts = Dictionary(
        uniqueKeysWithValues: fixture.expected.reasons.map { reason in
          let verdict = reason.chapter <= fixture.finals ? Verdict(.settled) : reason.reason.map { Verdict(.violated, $0) } ?? Verdict(.holds)
          return (reason.chapter, verdict)
        })
      let expectedMilestones = Dictionary(
        uniqueKeysWithValues: fixture.expected.milestones.map { ($0.milestone, MilestoneSnapshot($0.state, planned: $0.plannedChapter, reached: $0.reachedChapter)) })
      #expect(try await PlanWorldTables.verdicts(novel, in: store) == expectedVerdicts, "case \(index)")
      #expect(try await PlanWorldTables.milestones(novel, in: store) == expectedMilestones, "case \(index)")
    }
  }
}
