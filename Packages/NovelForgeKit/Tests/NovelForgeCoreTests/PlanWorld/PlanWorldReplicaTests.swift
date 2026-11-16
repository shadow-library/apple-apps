import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func book(seed: UInt64) async throws -> CausalReplicas {
  let reconciler = try Projection.reconciler()
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    for key in ["rise", "fall"] { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
    try PlanWorldWrites.secret(novel: novel, "ledger", unlock: unlock(.milestone("rise")), in: &transaction)
  }
  try await replicas.settle()
  return replicas
}

private func plan(_ chapter: Int, _ contract: ChapterContract, on index: Int, in replicas: CausalReplicas) async throws {
  _ = try await replicas.write(index) { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(contract), in: &$0) }
}

private struct Derived: Equatable {
  let claims: Set<Claim>
  let milestones: [String: MilestoneSnapshot]
  let verdicts: [Int: Verdict]
}

private func derivedOnEach(_ replicas: CausalReplicas) async throws -> [Derived] {
  var results = [Derived]()
  for index in 0..<replicas.count {
    let store = await replicas.store(index)
    results.append(
      Derived(
        claims: try await PlanWorldTables.claims(novel, in: store), milestones: try await PlanWorldTables.milestones(novel, in: store),
        verdicts: try await PlanWorldTables.verdicts(novel, in: store)))
  }
  return results
}

@Suite("Plan world across replicas", .timeLimit(.minutes(2)))
struct PlanWorldReplicaTests {
  @Test
  func shouldLetTheEarliestChapterHoldWhenTwoDevicesClaimTheSameMilestone() async throws {
    let replicas = try await book(seed: 0xD20D)
    try await plan(3, contract(claims: ["rise"]), on: 0, in: replicas)
    try await plan(2, contract(claims: ["rise"]), on: 1, in: replicas)
    try await replicas.settle()
    let expected = Derived(
      claims: [Claim("rise", 2, .holds, holder: 2), Claim("rise", 3, .duplicate, holder: 2)],
      milestones: ["rise": MilestoneSnapshot("planned", planned: 2), "fall": MilestoneSnapshot("open")], verdicts: [2: Verdict(.holds), 3: Verdict(.holds)])
    #expect(try await derivedOnEach(replicas) == [expected, expected, expected])
  }

  @Test
  func shouldReachTheMilestoneAFinalizeCopiedWhileAnotherDeviceDroppedTheClaim() async throws {
    let replicas = try await book(seed: 0xD20E)
    try await plan(1, contract(claims: ["rise"]), on: 0, in: replicas)
    try await replicas.settle()
    _ = try await replicas.write(0) { try PlanWorldWrites.finalize(novel: novel, chapter: 1, contract(claims: ["rise"]), in: &$0) }
    try await plan(1, contract(), on: 1, in: replicas)
    try await plan(2, contract(learns: [Learn("mara", "ledger")], claims: ["rise"]), on: 1, in: replicas)
    try await replicas.settle()
    let expected = Derived(
      claims: [Claim("rise", 1, .canon, .holds, holder: 1), Claim("rise", 2, .duplicate, holder: 1)],
      milestones: ["rise": MilestoneSnapshot("reached", planned: 1, reached: 1), "fall": MilestoneSnapshot("open")],
      verdicts: [1: Verdict(.settled), 2: Verdict(.holds)])
    #expect(try await derivedOnEach(replicas) == [expected, expected, expected])
  }

  @Test
  func shouldUnlockAnEndingGatedRevealOnlyFromTheLatestEndingWhenTwoDevicesMarkOne() async throws {
    let replicas = try await book(seed: 0xD210)
    _ = try await replicas.write(0) { try PlanWorldWrites.secret(novel: novel, "heir", unlock: unlock(.ending), in: &$0) }
    try await replicas.settle()
    try await plan(3, contract(learns: [Learn("mara", "heir")], ending: true), on: 0, in: replicas)
    try await plan(6, contract(ending: true), on: 1, in: replicas)
    try await plan(4, contract(learns: [Learn("mara", "heir")]), on: 2, in: replicas)
    try await replicas.settle()
    let ending = "heir (needs the planned ending or later)"
    let expected = Derived(
      claims: [], milestones: ["rise": MilestoneSnapshot("open"), "fall": MilestoneSnapshot("open")],
      verdicts: [3: Verdict(.violated, ending), 4: Verdict(.violated, ending), 6: Verdict(.holds)])
    #expect(try await derivedOnEach(replicas) == [expected, expected, expected])
    for index in 0..<replicas.count { #expect(try await PlanWorldTables.rivalEndings(novel, in: await replicas.store(index)) == [3: 6]) }
  }

  @Test
  func shouldFlagAClaimOnAMilestoneAnotherDeviceRemovedAndUnflagItOnRestore() async throws {
    let replicas = try await book(seed: 0xD20F)
    _ = try await replicas.write(0) { _ = try MilestoneRecord.remove(novel: novel, milestone: "rise", in: &$0) }
    try await plan(1, contract(claims: ["rise"]), on: 1, in: replicas)
    try await plan(2, contract(learns: [Learn("mara", "ledger")]), on: 2, in: replicas)
    try await replicas.settle()
    let removed = Derived(
      claims: [Claim("rise", 1, .unknown)], milestones: ["fall": MilestoneSnapshot("open")], verdicts: [1: Verdict(.holds), 2: Verdict(.holds)])
    #expect(try await derivedOnEach(replicas) == [removed, removed, removed])
    _ = try await replicas.write(2) { _ = try MilestoneRecord(novel: novel, milestone: "rise", label: "Milestone rise").restore(in: &$0) }
    try await replicas.settle()
    let restored = Derived(
      claims: [Claim("rise", 1, .holds, holder: 1)], milestones: ["rise": MilestoneSnapshot("planned", planned: 1), "fall": MilestoneSnapshot("open")],
      verdicts: [1: Verdict(.holds), 2: Verdict(.holds)])
    #expect(try await derivedOnEach(replicas) == [restored, restored, restored])
  }
}
