import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

private func expectRebuilt(_ store: VaultStore) async throws {
  let comparison = try await Projection.compare(try Projection.reconciler(chapterAreaDerivations), in: store)
  #expect(comparison.incremental == comparison.rebuilt)
}

private func milestoneStore() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  try await write(store) { transaction in
    for key in ["rise", "fall"] { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
  }
  return store
}

private func milestones(_ store: VaultStore) async throws -> [String: MilestoneSnapshot] {
  try await PlanWorldTables.milestones(novel, in: store)
}

@Suite("Canon milestones", .timeLimit(.minutes(2)))
struct CanonMilestoneTests {
  // chapter-finalization.graph.ts:177: a chapter finalized without a review reaches what its plan claims
  @Test func shouldReachWhatAnUnreviewedCanonClaims() async throws {
    let store = try await milestoneStore()
    try await write(store) { transaction in try CanonWrites.finalize(novel: novel, chapter: 1, review: nil, contract: contract(claims: ["rise"]), in: &transaction) }
    #expect(try await milestones(store)["rise"] == MilestoneSnapshot("reached", planned: 1, reached: 1))
  }

  // finalize-review-gate.ts:161-166 and review-event-apply.ts:216-222
  @Test func shouldReachOnlyTheClaimsTheReviewKeptAndAKeptUnclaimedMilestone() async throws {
    let store = try await milestoneStore()
    try await write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 3, planContent(contract(claims: ["rise"])), in: &transaction)
      try CanonWrites.finalize(
        novel: novel, chapter: 1, review: review([Kept.milestone("fall")], unreached: ["rise"]), contract: contract(claims: ["rise"]), in: &transaction)
    }
    #expect(try await milestones(store) == ["rise": MilestoneSnapshot("planned", planned: 3), "fall": MilestoneSnapshot("reached", planned: 1, reached: 1)])
    #expect(try await PlanWorldTables.claims(novel, in: store) == [Claim("rise", 3, .holds, holder: 3), Claim("fall", 1, .canon, .holds, holder: 1)])
    try await expectRebuilt(store)
  }

  // review-event-apply.ts:217-221: a kept answer of "not reached" reaches nothing, and an earlier reach stands
  @Test func shouldKeepTheEarliestReachAndIgnoreAKeptUnreachedItem() async throws {
    let store = try await milestoneStore()
    try await write(store) { transaction in
      try CanonWrites.finalize(novel: novel, chapter: 1, review: review([Kept.milestone("rise"), Kept.milestone("fall", reached: false)]), in: &transaction)
      try CanonWrites.finalize(novel: novel, chapter: 2, review: review([Kept.milestone("rise")]), in: &transaction)
    }
    #expect(try await milestones(store) == ["rise": MilestoneSnapshot("reached", planned: 1, reached: 1), "fall": MilestoneSnapshot("open")])
  }

  @Test func shouldReachNothingFromAReviewThisVersionCannotRead() async throws {
    let store = try await milestoneStore()
    try await write(store) { transaction in try CanonWrites.finalize(novel: novel, chapter: 1, unreadable: .review, in: &transaction) }
    #expect(try await milestones(store)["rise"] == MilestoneSnapshot("open"))
  }
}

private func knowledgeStore() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  try await write(store) { transaction in
    for key in ["heir", "tide"] { try PlanWorldWrites.secret(novel: novel, key, revealChapter: 1, in: &transaction) }
    for key in ["mara", "tobin"] { try ChapterWrites.entity(novel: novel, key, in: &transaction) }
    try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
    try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
  }
  try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
  return store
}

/// Finalizes chapter 1 bound to its approval in force, recording `knowledge` as the finalizing device committed it.
private func finalize(_ store: VaultStore, knowledge: [KnowledgeReveal]?, kept: [ProposedChange] = []) async throws {
  try await write(store) { transaction in
    let approval = try ChapterLifecycleEntry.read(novel: novel, chapter: 1, in: transaction.database)?.approval
    let plan = try ChapterWrites.planContract(novel: novel, chapter: 1, in: transaction) ?? ChapterContract()
    try CanonWrites.finalize(novel: novel, chapter: 1, review: review(kept), knowledge: knowledge, contract: plan, approval: approval, in: &transaction)
  }
}

private func knowledge(_ store: VaultStore) async throws -> Set<LedgerView> {
  try await ChapterTables.knowledge(novel, in: store)
}

private func moveReveal(of secret: String, to chapter: Int, in store: VaultStore) async throws {
  var edit = SecretEdit()
  edit.revealChapter = .set(chapter)
  let changes = edit
  try await write(store) { transaction in _ = try SecretRecord.edit(SecretRecord.ref(novel: novel, secret: secret), changes.fields, in: &transaction) }
}

/// E04 option A with the freeze: a canon that recorded its knowledge commits those pairs whatever the world says later, subject to the live-since cutoff.
@Suite("Canon knowledge", .timeLimit(.minutes(2)))
struct CanonKnowledgeTests {
  @Test func shouldKeepFrozenKnowledgeWhenTheRevealChapterMovesAfterFinalize() async throws {
    let store = try await knowledgeStore()
    try await finalize(store, knowledge: [KnowledgeReveal(entityKey: "mara", factKey: "heir")])
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    try await moveReveal(of: "heir", to: 4, in: store)
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    try await expectRebuilt(store)
  }

  @Test func shouldRecomputeWhenTheCanonRecordedNoKnowledge() async throws {
    let store = try await knowledgeStore()
    try await finalize(store, knowledge: nil)
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    try await moveReveal(of: "heir", to: 4, in: store)
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldCommitExactlyTheRecordedPairsOverThePlansLearns() async throws {
    let store = try await knowledgeStore()
    try await finalize(store, knowledge: [KnowledgeReveal(entityKey: "tobin", factKey: "tide")])
    #expect(try await knowledge(store) == [LedgerView("tide", "tobin", 1, .brief, .committed)])
  }

  @Test func shouldCommitNothingFromAnEmptyOrUnreadableRecordedSet() async throws {
    let empty = try await knowledgeStore()
    try await finalize(empty, knowledge: [])
    #expect(try await knowledge(empty).isEmpty)

    let unreadable = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
    try await write(unreadable) { transaction in
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
      try CanonWrites.finalize(novel: novel, chapter: 1, unreadable: .knowledge, terms: contract(learns: [Learn("mara", "heir")]), in: &transaction)
    }
    #expect(try await Projection.fetch(CanonBindingEntry.all(), in: unreadable).map(\.knowledgeState) == [.unreadable])
    #expect(try await knowledge(unreadable).isEmpty)
  }

  @Test func shouldStartAFrozenPairFreshWhenItsSecretIsCreatedAgain() async throws {
    let store = try await knowledgeStore()
    try await finalize(store, knowledge: [KnowledgeReveal(entityKey: "mara", factKey: "heir")])
    try await write(store) { transaction in _ = try SecretRecord.remove(novel: novel, secret: "heir", in: &transaction) }
    try await write(store) { transaction in try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }

  @Test func shouldKeepTheAuthorsManualRevealAndRetractionOverAFrozenPair() async throws {
    let store = try await knowledgeStore()
    try await write(store) { transaction in
      try ChapterWrites.reveal(novel: novel, fact: "heir", entity: "mara", chapter: 5, in: &transaction)
      try ChapterWrites.reveal(novel: novel, fact: "tide", entity: "tobin", chapter: 5, in: &transaction)
      try ChapterWrites.retract(novel: novel, fact: "tide", entity: "tobin", in: &transaction)
    }
    try await finalize(store, knowledge: [KnowledgeReveal(entityKey: "mara", factKey: "heir"), KnowledgeReveal(entityKey: "tobin", factKey: "tide")])
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 5, .manual, .committed)])
  }

  // review-event-apply.ts:203-214: a kept knowledge item lands at its chapter as generated, after the chapter's own learns and never over a row the pair holds
  @Test func shouldCommitAKeptKnowledgeItemAsGeneratedWithoutDisplacingARow() async throws {
    let store = try await knowledgeStore()
    try await finalize(
      store, knowledge: [KnowledgeReveal(entityKey: "mara", factKey: "heir")],
      kept: [Kept.knowledge("mara", "heir"), Kept.knowledge("tobin", "tide"), Kept.knowledge("ghost", "tide")])
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed), LedgerView("tide", "tobin", 1, .generated, .committed)])
    try await write(store) { transaction in
      try ChapterWrites.reveal(novel: novel, fact: "tide", entity: "tobin", chapter: 3, in: &transaction)
      try ChapterWrites.retract(novel: novel, fact: "tide", entity: "tobin", in: &transaction)
    }
    #expect(try await knowledge(store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    try await expectRebuilt(store)
  }

  // review-event-apply.ts:209: the fact and the learner must exist when the canon is written
  @Test func shouldSkipAKeptKnowledgeItemWhoseLearnerWasCreatedAfterTheCanon() async throws {
    let store = try await knowledgeStore()
    try await finalize(store, knowledge: [], kept: [Kept.knowledge("elias", "tide")])
    try await write(store) { transaction in try ChapterWrites.entity(novel: novel, "elias", in: &transaction) }
    #expect(try await knowledge(store).isEmpty)
  }
}
