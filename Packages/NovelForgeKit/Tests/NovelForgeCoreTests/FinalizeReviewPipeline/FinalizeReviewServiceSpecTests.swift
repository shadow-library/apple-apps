import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

/// apps/novel-forge-server/tests/finalize-review/finalize-review.service.spec.ts, through the engine: approval requests the job, the pipeline reads the review,
/// and the author answers it with the decision operations.
@Suite("Finalize review pipeline", TestTimeLimit.standard)
struct FinalizeReviewServiceSpecTests {
  // finalize-review.service.spec.ts:86
  @Test func shouldReadTheApprovedRevisionIntoConsequentialAndRoutineItemsAndAppendTheReview() async throws {
    let world = try await FinalizeReviewWorld()
    let engine = try world.engine()
    let job = try await world.prepared(on: engine, autoKeep: [])
    let reviews = try await world.reviews()
    #expect(reviews.count == 1)
    let review = try #require(reviews.first?.record)
    let head = try await world.head()
    #expect(review.job == job.key && !review.isolated && review.draftRevision == head)
    #expect(try await world.items(.consequential).map(\.category) == [.promise])
    #expect(try await world.items(.routine).map(\.category) == [.appearance, .characterState])
    let request = try #require(world.provider.requests.first)
    #expect(request.messages.contains { $0.text.contains("Chapter 1 prose:\n\n\(FinalizeReviewScript.prose)") })
    #expect(request.messages.contains { $0.text.contains("mira (character): Mira") })
  }

  // finalize-review.service.spec.ts:99
  @Test func shouldKeepRoutineItemsOfTheAuthorsAutoKeepCategoriesWithoutAsking() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(), autoKeep: [.appearance])
    #expect(
      try await world.items(.routine).map { [$0.category.rawValue, $0.decision?.rawValue ?? "nil", "\($0.autoKept)"] } == [
        ["appearance", "kept", "true"], ["character_state", "nil", "false"],
      ])
    #expect(try await world.open() == (1, 1))
    let stored = try #require(try await world.reviews().first?.record.items)
    #expect(stored.map { "\($0.key) \($0.autoDecision?.rawValue ?? "nil")" } == ["appearance:mira kept", "character_state:mira nil", "promise:thread:lamp_debt nil"])
    #expect(try await answers(world).isEmpty)
  }

  // finalize-review.service.spec.ts:114
  @Test func shouldPersistAnInlineEditAsTheValueFinalizeApplies() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(), autoKeep: [])
    let answer = try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "character_state:mira", decision: .edited, edit: ["location": "the lighthouse"])
    #expect(answer.edit?["state"]?["location"] == "the lighthouse" && answer.edit?["category"] == "character_state")
    let edited = try #require(try await world.items(.routine).first { $0.category == .characterState })
    #expect(edited.decision == .edited)
    guard case .characterState(let state)? = edited.edited else { throw EngineFixtureError(description: "no edited state") }
    #expect(state.entityKey == "mira" && state.location == "the lighthouse")
  }

  // finalize-review.service.spec.ts:125
  @Test func shouldNeverAskASkippedItemAgainEvenWhenTheRevisionIsReadAgain() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(), FinalizeReviewScript.reply()])
    let engine = try world.engine()
    let job = try await world.prepared(on: engine)
    try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .skipped, reason: " the debt is only half paid ")
    let input = try #require(FinalizeReviewJobInput(json: try await payload(world, job)))
    let rerun = try await engine.request(
      NovelJobRequest(kind: .finalizeReview, novel: world.novel, chapter: 1, fingerprint: input.fingerprint, payload: input.json, rerun: true))
    #expect(try await world.run(engine, rerun.ref) == .settled(.succeeded))
    #expect(try await world.reviews().count == 2)
    let payoff = try #require(try await world.items(.consequential).first)
    #expect(payoff.decision == .skipped && payoff.reason == "the debt is only half paid")
    #expect(try await world.open().consequential == 0)
  }

  // finalize-review.service.spec.ts:139
  @Test func shouldCarryASkipIntoTheNextRevisionsReviewEvenWhenTheReReadWordsTheUpdateDifferently() async throws {
    let reworded = FinalizeReviewScript.replacing(
      FinalizeReviewScript.extraction, "threads", with: [["threadKey": "lamp_debt", "status": "closed", "summary": "The keeper is repaid at last"]])
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(), FinalizeReviewScript.reply(reworded)])
    let engine = try world.engine()
    try await world.prepared(on: engine)
    try await world.store.decideFinalizeItem(novel: world.novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .skipped, reason: "not paid yet")
    let revision = try await world.draft("\(FinalizeReviewScript.prose) She pauses.")
    let job = try await world.approve()
    #expect(try await world.run(engine, job) == .settled(.succeeded))
    #expect(try await world.inForce().read.record.draftRevision == revision)
    let payoff = try #require(try await world.items(.consequential).first)
    #expect(payoff.claim == "Paid off: The keeper is repaid at last" && payoff.decision == .skipped && payoff.reason == "not paid yet")
  }

  // finalize-review.service.spec.ts:156
  @Test func shouldRefuseASkipWithoutAReasonAndAnyDecisionOnceTheProseMovedPastTheReview() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine())
    let (store, novel) = (world.store, world.novel)
    await world.expectRefusal("FRV_010") { () throws(FinalizeAnswerError) in
      try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .skipped, reason: "  ")
    }
    await world.expectRefusal("FRV_008") { () throws(FinalizeAnswerError) in
      try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "promise:thread:other", decision: .kept)
    }
    await world.expectRefusal("FRV_009") { () throws(FinalizeAnswerError) in
      try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "appearance:mira", decision: .edited, edit: ["entityKey": "lin"])
    }
    try await world.draft("\(FinalizeReviewScript.prose) Edited.")
    await world.expectRefusal("FRV_004") { () throws(FinalizeAnswerError) in
      try await store.decideFinalizeItem(novel: novel, chapter: 1, item: "promise:thread:lamp_debt", decision: .kept)
    }
  }

  // finalize-review.service.spec.ts:167, read once the chapter is isolated at approval: the read and what it proposes quote nothing of the prose.
  @Test func shouldWithholdAnIsolatedChaptersEvidenceFromTheReviewItReads() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine(unrestrictedAvailable: true), isolated: true)
    #expect(try await world.reviews().first?.record.isolated == true)
    let state = try #require(try await world.inForce().resolved.first { $0.category == .characterState })
    #expect(state.evidence == FinalizeReviewItem.withheldEvidence)
    guard case .characterState(let proposed) = state.proposed else { throw EngineFixtureError(description: "no state") }
    #expect(proposed.evidence == FinalizeReviewItem.withheldEvidence)
    #expect(state.triage == .consequential && state.decision == nil)
    #expect(world.provider.requests.first?.messages.contains { $0.text.contains("This chapter is walled off from the rest of the book.") } == true)
  }

  // finalize-review.service.spec.ts:180
  @Test func shouldKeepEveryRoutineItemWithoutAskingWhileTheAuthorHasNotChosenCategories() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine())
    #expect(
      try await world.items(.routine).map { "\($0.category.rawValue) \($0.decision?.rawValue ?? "nil") \($0.autoKept)" } == [
        "appearance kept true", "character_state kept true",
      ])
  }

  // finalize-review.service.spec.ts:193
  @Test func shouldFinalizeTheChapterOnceApprovalLeftNothingToAsk() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    try await world.prepared(on: try world.engine())
    #expect(world.recorder.finalized == [1])
    #expect(try await world.reviews().count == 1)
  }

  // finalize-review.service.spec.ts:202
  @Test func shouldLeaveTheChapterForTheAuthorWhileAnUnsureUpdateWaitsOnThem() async throws {
    let world = try await FinalizeReviewWorld()
    try await world.prepared(on: try world.engine())
    #expect(world.recorder.finalized.isEmpty)
    #expect(try await world.open() == (1, 0))
  }

  // finalize-review.service.spec.ts:211, 221: a refusal or failure of the commit leaves the prepared review, and the job succeeds.
  @Test func shouldLeaveAnAnsweredReviewWaitingWhenFinalizeRefusesTheChapter() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    world.recorder.refuse(with: .finalizeOutOfOrder(1))
    let job = try await world.prepared(on: try world.engine())
    #expect(world.recorder.finalized.isEmpty)
    #expect(try await world.reviews().count == 1)
    #expect(try await world.base.status(job).phase == .succeeded)
  }

  // finalize-review.service.spec.ts:254
  @Test func shouldNeverFinalizeAnIsolatedChapterOnItsOwnEvenWhenItsReviewAsksNothing() async throws {
    var nothing = FinalizeReviewScript.replacing(FinalizeReviewScript.confident, "appeared", with: [])
    nothing = FinalizeReviewScript.replacing(nothing, "characterStates", with: [])
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.replacing(nothing, "chapterSummary", with: " "))])
    try await world.prepared(on: try world.engine(unrestrictedAvailable: true), isolated: true)
    #expect(try await world.open() == (0, 0))
    #expect(world.recorder.finalized.isEmpty)
  }

  // finalize-review.service.spec.ts:264
  @Test func shouldAskTheRoutineCategoriesTheAuthorTurnedOffAndFinalizeNothingUntilTheyAnswer() async throws {
    let world = try await FinalizeReviewWorld(replies: [FinalizeReviewScript.reply(FinalizeReviewScript.confident)])
    try await world.prepared(on: try world.engine(), autoKeep: [])
    #expect(world.recorder.finalized.isEmpty)
    #expect(try await world.open() == (0, 2))
    #expect(try await world.store.keepRoutineFinalizeItems(novel: world.novel, chapter: 1) == 2)
    #expect(try await world.open() == (0, 0))
    #expect(try await answers(world).map { "\($0.decision.rawValue) \($0.auto)" } == ["kept false", "kept false"])
  }

  @Test func shouldStoreEachAutoKeepCategoryOnceInTheOrderGiven() async throws {
    let world = try await FinalizeReviewWorld()
    #expect(try await world.store.setFinalizeAutoKeep(novel: world.novel, categories: [.entity, .appearance, .entity]) == [.entity, .appearance])
    let novel = world.novel
    let stored = try await world.store.read { transaction in try NovelRecord.read(id: novel, in: transaction).entry?.record.autoKeep }
    #expect(stored == [.known(.entity), .known(.appearance)])
  }

  private func answers(_ world: FinalizeReviewWorld) async throws -> [StoredFinalizeAnswer] {
    let novel = world.novel
    return try await world.store.read { transaction in try FinalizeDecisionRecord.listing(novel: novel, chapter: 1, in: transaction).live.map(\.answer) }
  }

  private func payload(_ world: FinalizeReviewWorld, _ job: EntityRef) async throws -> JSONValue {
    try #require(try await world.store.read { transaction in try JobSnapshot.load(job, in: transaction) }).job.request.payload
  }
}
