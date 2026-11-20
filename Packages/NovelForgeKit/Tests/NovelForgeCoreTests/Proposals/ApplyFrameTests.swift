import Foundation
import ShadowCore
import ShadowStore
import ShadowText
import Testing

@testable import NovelForgeCore

private let context = ApplyContext(novel: SchemaFixture.novel, intent: .apply, now: Date(timeIntervalSince1970: 1_700_000_000))

private func perform(_ store: VaultStore, _ call: ContentCall) async throws -> Result<AppliedStep, ApplyError> {
  try await store.write { transaction in
    do throws(ApplyError) {
      return .success(try ApplyFrame.perform(call, context: context, in: &transaction))
    } catch {
      return .failure(error)
    }
  }
}

private func call(_ json: String) throws -> ContentCall {
  .op(try #require(try applyOps(json).first))
}

private func planContent(learns: [KnowledgeReveal] = [], claims: [String] = [], ending: Bool = false, volume: String? = nil) -> ChapterPlanContent {
  let contract = ChapterContract(pov: ["mara"], learns: learns.map(ContractLearn.init), claimedMilestones: claims, isEnding: ending)
  return ChapterPlanContent(body: "The plan.", volume: volume, contract: contract)
}

private func plan(_ chapter: Int, learns: [KnowledgeReveal] = [], claims: [String] = [], ending: Bool = false, volume: String? = nil) throws -> PlanOverlay.Edit {
  let content = planContent(learns: learns, claims: claims, ending: ending, volume: volume)
  return .plan(chapter: chapter, ref: try ChapterPlanRecord.ref(novel: SchemaFixture.novel, chapter: chapter), content: content)
}

private func fact(_ key: String, revealChapter: Int? = nil, unlock: UnlockTerm? = nil) -> PlanOverlay.Edit {
  let condition = unlock.map { FactUnlock.condition(UnlockCondition(all: [$0])) }
  return .fact(DisclosureFact(factKey: key, text: "The ledger is forged.", source: .manual, revealChapter: revealChapter, unlock: condition))
}

private func writing(_ store: VaultStore, written: Bool, thenThrowing error: ApplyError?) async throws -> Result<AppliedStep, ApplyError> {
  let milestone = MilestoneRecord(novel: SchemaFixture.novel, milestone: "rise", label: "Rise")
  let upsert = try call(#"{"op":"milestone.upsert","milestoneKey":"rise","label":"Rise"}"#)
  return try await store.write { transaction in
    do throws(ApplyError) {
      let step = try ApplyFrame.perform(upsert, context: context, in: &transaction) {
        _, _, transaction throws(ApplyError) in
        if written {
          do throws(StoreError) { _ = try milestone.create(in: &transaction) } catch { throw .store(error) }
        }
        if let error { throw error }
        return HandlerOutcome()
      }
      return .success(step)
    } catch {
      return .failure(error)
    }
  }
}

@Suite("Apply frame")
struct ApplyFrameTests {
  @Test func shouldRefuseACallOverAnUnreadableRecordBeforeAnyHandlerRuns() async throws {
    let store = try SchemaFixture.store()
    let novel = SchemaFixture.novel
    let broken = NovelForgeKey.volumeKey(novel: novel, volume: "broken")
    _ = try await store.write { transaction in
      _ = try VolumeRecord(novel: novel, volume: "kept", ordinal: 1).create(in: &transaction)
      return try transaction.set(broken.ref, ["natural_key": broken.stored, "removed": .bool(false)])
    }
    let unreadable = try await perform(store, try call(#"{"op":"volume.remove","volumeKey":"broken"}"#))
    #expect(throws: ApplyError.unreadable(ref: "volume:broken")) { try unreadable.get() }
    let readable = try await perform(store, try call(#"{"op":"volume.remove","volumeKey":"kept"}"#))
    #expect(try readable.get().postState[JSString("volume:kept")] == .missing)
  }

  // content-op-handlers.ts:25
  @Test func shouldApplyAnOrganiseRuleAsNoWrite() async throws {
    let store = try SchemaFixture.store()
    let outcome = try await perform(store, try call(#"{"op":"organise.rule","rule":"Keep it short.","optionId":"o1"}"#))
    #expect(try outcome.get() == AppliedStep(result: nil, inverse: nil, priorState: [:], postState: [:], planEdits: []))
  }

  @Test func shouldTurnAHandlerErrorAfterAWriteIntoAPartialWrite() async throws {
    let refused = ApplyError.domain(.milestoneExists("rise"))
    let partial = try await writing(try SchemaFixture.store(), written: true, thenThrowing: refused)
    #expect(throws: ApplyError.partialWrite(ref: "milestone:rise")) { try partial.get() }
    let clean = try await writing(try SchemaFixture.store(), written: false, thenThrowing: refused)
    #expect(throws: refused) { try clean.get() }
    let applied = try await writing(try SchemaFixture.store(), written: true, thenThrowing: nil).get()
    #expect(applied.priorState[JSString("milestone:rise")] == .missing)
    #expect(applied.postState[JSString("milestone:rise")]?.exists == true)
  }

  @Test func shouldNeverReachAHandlerForAnAction() async throws {
    let store = try SchemaFixture.store()
    let outcome = try await perform(store, try call(#"{"op":"action.finalize"}"#))
    #expect(throws: ApplyError.noHandler(.actionFinalize)) { try outcome.get() }
  }
}

// apps/novel-forge-server/src/modules/refinement/apply/apply-rules.ts:46-51 over common/plan-state.ts:32-46
@Suite("Plan ops overlaid")
struct PlanOpsOverlayTests {
  private func enforce(_ book: ChapterBook, _ edits: [PlanOverlay.Edit]) async throws {
    let novel = book.novel
    try await book.run { try ApplyFrame.enforcePlanOps(PlanOverlay(edits), novel: novel, in: $0) }
  }

  private func refuse(_ book: ChapterBook, _ expected: DomainError, _ edits: [PlanOverlay.Edit], sourceLocation: SourceLocation = #_sourceLocation) async {
    let novel = book.novel
    await book.expect(expected, sourceLocation: sourceLocation) { try ApplyFrame.enforcePlanOps(PlanOverlay(edits), novel: novel, in: $0) }
  }

  @Test func shouldJudgeAWrittenPlanAgainstAFactTheSameChangeSetMoves() async throws {
    let book = try await ChapterBook.make()
    let early = try plan(2, learns: [reveal("mara", "tide")])
    await refuse(book, .planRevealsLocked(chapter: 2, violations: "tide (needs chapter 5 or later)"), [early])
    try await enforce(book, [early, fact("tide", revealChapter: 2)])
    try await enforce(book, [fact("tide", revealChapter: 2), early])
    await refuse(book, .planRevealsLocked(chapter: 2, violations: "tide (needs chapter 9 or later)"), [fact("tide", revealChapter: 2), early, fact("tide", revealChapter: 9)])
    try await enforce(book, [early, .factRemoved("tide")])
  }

  @Test func shouldJudgeClaimsAgainstMilestonesTheChangeSetAddsAndRemoves() async throws {
    let book = try await ChapterBook.make()
    let ghost = try plan(3, claims: ["ghost"])
    await refuse(book, .planClaims(chapter: 3, reason: "ghost is not a milestone of this novel"), [ghost])
    try await enforce(book, [ghost, .milestone("ghost")])
    await refuse(book, .planClaims(chapter: 3, reason: "ghost is not a milestone of this novel"), [.milestone("ghost"), ghost, .milestoneRemoved("ghost")])
    await refuse(book, .planClaims(chapter: 3, reason: "rise is not a milestone of this novel"), [try plan(3, claims: ["rise"]), .milestoneRemoved("rise")])
  }

  @Test func shouldJudgeEveryWrittenPlanInChapterOrderAgainstTheOthers() async throws {
    let book = try await ChapterBook.make()
    await refuse(book, .planClaims(chapter: 2, reason: "rise is already claimed by the plan for chapter 5"), [try plan(5, claims: ["rise"]), try plan(2, claims: ["rise"])])
    await refuse(book, .endingPlanned(9), [try plan(9, ending: true), try plan(4, ending: true)])
    try await book.plan(2, claims: ["rise"])
    await refuse(book, .planClaims(chapter: 3, reason: "rise is already claimed by the plan for chapter 2"), [try plan(3, claims: ["rise"])])
    try await enforce(book, [.planRemoved(chapter: 2), try plan(3, claims: ["rise"])])
  }

  @Test func shouldJudgeAVolumeGatedRevealAgainstTheVolumesTheChangeSetLeaves() async throws {
    let book = try await ChapterBook.make()
    let gated = try plan(3, learns: [reveal("mara", "vault")], volume: "v2")
    let vault = fact("vault", unlock: .volume("v2"))
    let refusal = DomainError.planRevealsLocked(chapter: 3, violations: "vault (needs volume v2 reached)")
    await refuse(book, refusal, [vault, gated])
    try await enforce(book, [vault, .volume("v2", ordinal: 2), gated])
    await refuse(book, refusal, [vault, .volume("v2", ordinal: 2), gated, .volumeRemoved("v2")])
  }

  @Test func shouldJudgeAnEndingGatedRevealAgainstTheLatestOfTwoStoredEndings() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 4, planContent(ending: true), in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 9, planContent(ending: true), in: &transaction)
    }
    let seal = fact("seal", unlock: .ending)
    await refuse(book, .planRevealsLocked(chapter: 6, violations: "seal (needs the planned ending or later)"), [seal, try plan(6, learns: [reveal("mara", "seal")])])
    try await enforce(book, [seal, try plan(10, learns: [reveal("mara", "seal")])])
  }

  @Test func shouldCheckOnlyPlansTheChangeSetWrites() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(2, learns: [reveal("mara", "heir")])
    try await enforce(book, [fact("heir", revealChapter: 8), .milestoneRemoved("rise"), .volume("v", ordinal: 1), .volumeRemoved("w")])
    try await enforce(book, [try plan(3, learns: [reveal("mara", "tide")]), .planRemoved(chapter: 3)])
    try await enforce(book, [])
    await refuse(
      book, .planRevealsLocked(chapter: 2, violations: "heir (needs chapter 8 or later)"), [fact("heir", revealChapter: 8), try plan(2, learns: [reveal("mara", "heir")])])
  }

  @Test func shouldRefuseWhileThePlanWorldIsFaulted() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(2)
    try await book.tamper("DELETE FROM nf_derived_plan_world")
    await refuse(book, .planStateUnavailable(4), [try plan(6), try plan(4)])
  }

  @Test func shouldListTheWrittenChaptersOnceInOrder() throws {
    let overlay = PlanOverlay([try plan(9), .planRemoved(chapter: 1), try plan(3), try plan(9), .milestone("m")])
    #expect(overlay.written == [3, 9])
    var grown = PlanOverlay()
    grown.append(overlay.edits)
    #expect(grown == overlay)
  }
}
