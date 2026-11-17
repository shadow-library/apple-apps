import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Chapter plan writes", .timeLimit(.minutes(2)))
struct PlanWriteTests {
  @Test func shouldCreateAPlanInTheNovelsContentModeAndNearestVolume() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      var edit = NovelEdit()
      edit.contentMode = .set(.known(.unrestricted))
      _ = try NovelRecord.edit(id: novel, edit, in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(volume: "one", contract()), in: &transaction)
    }
    try await book.plan(3, PlanEdit(body: "Three."))
    let content = try #require(try await book.planContent(3))
    #expect(content.volume == "one")
    #expect(content.contentMode == .known(.unrestricted))
    #expect(content.handEdited)
    #expect(content.contract == ChapterContract())
  }

  @Test func shouldKeepAnExistingPlansVolumeAndFieldsThatAreNotSent() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.run { transaction in
      var content = planContent(volume: "two", contract(learns: [Learn("mara", "heir")], claims: ["rise"]))
      content.guidance = "Keep it quiet."
      content.densityRisk = "high"
      try PlanWorldWrites.putPlan(novel: novel, chapter: 2, content, in: &transaction)
    }
    try await book.plan(2, PlanEdit(body: "Rewritten."))
    let content = try #require(try await book.planContent(2))
    #expect(content.body == "Rewritten.")
    #expect(content.volume == "two")
    #expect(content.guidance == "Keep it quiet.")
    #expect(content.densityRisk == nil)
    #expect(content.contract.reveals == [reveal("mara", "heir")])
    #expect(content.contract.claimedMilestones == ["rise"])
  }

  @Test func shouldTrimTextFieldsClearBlankOnesAndKeepTheTitleWhenItIsBlank() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.", title: "  Dawn  ")
    edit.chapterPurpose = .set("  Why.  ")
    edit.pov = .set(" mara ")
    edit.guidance = .set("Quiet.")
    edit.direction = .set("North.")
    edit.claimedMilestones = .set(["rise"])
    try await book.plan(1, edit)
    var second = PlanEdit(body: "Body.", title: "   ")
    second.guidance = .set("   ")
    second.direction = .set(nil)
    second.claimedMilestones = .set(nil)
    try await book.plan(1, second)
    let content = try #require(try await book.planContent(1))
    #expect(content.title == "Dawn")
    #expect(content.chapterPurpose == "Why.")
    #expect(content.pov == "mara")
    #expect(content.guidance == nil)
    #expect(content.direction == nil)
    #expect(content.contract.claimedMilestones == [])
  }

  @Test func shouldNormalizeClaimedMilestones() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    edit.claimedMilestones = .set([" rise ", "", "rise"])
    try await book.plan(1, edit)
    #expect(try await book.planContent(1)?.contract.claimedMilestones == ["rise"])
  }

  @Test func shouldComposeTheScenesIntoTheBodyAndStoreThemNormalized() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Objective.\nScene 1. Old.\n\nScene 2. Older.\nAfter.")
    edit.scenes = .set([PlanScene(BriefScene(summary: " They land ", pov: "mara", goal: "  ", beats: ["  a  b ", " "]))])
    try await book.plan(1, edit)
    let content = try #require(try await book.planContent(1))
    #expect(content.body == "Objective.\nScene 1. They land. Beats: a b. POV: mara.\nAfter.")
    #expect(content.scenes == [PlanScene(BriefScene(summary: "They land", pov: "mara", beats: ["a  b"]))])
    var cleared = PlanEdit(body: content.body)
    cleared.scenes = .set(nil)
    try await book.plan(1, cleared)
    #expect(try await book.planContent(1)?.body == "Objective.\nAfter.")
    #expect(try await book.planContent(1)?.scenes == nil)
  }

  @Test func shouldReplaceTheEndingContractTrimmedAndRemoveItWithNil() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    let ending = ChapterEndingContract(hookType: .known(.turn), emotionalBeat: " dread ", openQuestion: "Who?", handoffState: "Night.", mustNotResolve: [" thread:a ", " "])
    edit.endingContract = .set(ending)
    try await book.plan(1, edit)
    #expect(
      try await book.planContent(1)?.endingContract
        == ChapterEndingContract(hookType: .known(.turn), emotionalBeat: "dread", openQuestion: "Who?", handoffState: "Night.", mustNotResolve: ["thread:a"]))
    var removed = PlanEdit(body: "Body.")
    removed.endingContract = .set(nil)
    try await book.plan(1, removed)
    #expect(try await book.planContent(1)?.endingContract == nil)
  }

  @Test func shouldRestoreARemovedPlanAsANewOne() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.plan(1, learns: [reveal("mara", "heir")])
    try await book.run { _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: &$0) }
    try await book.plan(1, PlanEdit(body: "Again."))
    let content = try #require(try await book.planContent(1))
    #expect(content.body == "Again.")
    #expect(content.contract == ChapterContract())
  }

  @Test func shouldWriteNothingWhenThePlanIsUnchanged() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1)
    let before = try await book.store.pendingChanges(limit: .max).count
    try await book.plan(1)
    #expect(try await book.store.pendingChanges(limit: .max).count == before)
  }

  @Test func shouldRefuseMalformedScenes() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    edit.scenes = .set([PlanScene(BriefScene(summary: "  ", pov: " ", estimatedWords: -1))])
    let expected = DomainError.scenesMalformed(
      "scenes[0].summary must be a non-empty string; scenes[0].pov must be an entity key or null; scenes[0].estimatedWords must be an integer >= 1")
    await book.expectPlan(expected, 1, edit)
  }

  @Test func shouldRefuseAnIncompleteEndingContract() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    edit.endingContract = .set(ChapterEndingContract(hookType: .known(.turn), emotionalBeat: " ", openQuestion: "Who?", handoffState: ""))
    await book.expectPlan(.endingIncomplete(fields: "emotionalBeat, handoffState"), 1, edit)
    edit.endingContract = .set(ChapterEndingContract(hookType: .unknown("twist"), emotionalBeat: "a", openQuestion: "b", handoffState: "c"))
    await book.expectPlan(.invalidKey(field: "endingContract.hookType"), 1, edit)
  }

  @Test func shouldRefuseAKnowledgeContractWithoutAPointOfViewOrWithMalformedKeys() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    edit.knowledge = .set(PlanKnowledge(pov: []))
    await book.expectPlan(.belowMinimum(field: "knowledgeContract.pov", minimum: 1), 1, edit)
    edit.knowledge = .set(PlanKnowledge(pov: ["mara"], learns: [reveal("Mara", "heir")]))
    await book.expectPlan(.invalidKey(field: "knowledgeContract.learns.entityKey"), 1, edit)
    edit.knowledge = .set(PlanKnowledge(pov: ["mara"], learns: [reveal("mara", "the heir")]))
    await book.expectPlan(.invalidKey(field: "knowledgeContract.learns.factKey"), 1, edit)
  }

  @Test func shouldRefuseAnUnknownContentModeAndAMissingNovelAndChapterZero() async throws {
    let book = try await ChapterBook.make()
    var edit = PlanEdit(body: "Body.")
    edit.contentMode = .set(.unknown("wild"))
    await book.expectPlan(.invalidKey(field: "contentMode"), 1, edit)
    let other = SchemaFixture.otherNovel
    await book.expect(.novelNotFound(other)) { try ChapterPlans.write(novel: other, chapter: 1, PlanEdit(body: "x"), in: &$0) }
    await book.expect(.belowMinimum(field: "chapter", minimum: 1)) { try ChapterPlans.write(novel: SchemaFixture.novel, chapter: 0, PlanEdit(body: "x"), in: &$0) }
  }

  @Test func shouldRefuseAPlanAtOrBeforeTheLatestFinalChapter() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.finalized(through: 2)
    await book.expect(.planFinal(1)) { try ChapterPlans.write(novel: novel, chapter: 1, PlanEdit(body: "x"), in: &$0) }
    await book.expect(.planFinal(2)) { try ChapterPlans.write(novel: novel, chapter: 2, PlanEdit(body: "x"), in: &$0) }
    try await book.plan(3)
  }

  @Test func shouldRefuseClaimsOfUnknownReachedOrClaimedMilestones() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(2, claims: ["rise"])
    let ghost = ChapterBook.planEdit(claims: ["ghost"])
    await book.expectPlan(.planClaims(chapter: 3, reason: "ghost is not a milestone of this novel"), 3, ghost)
    let taken = ChapterBook.planEdit(claims: ["rise"])
    await book.expectPlan(.planClaims(chapter: 3, reason: "rise is already claimed by the plan for chapter 2"), 3, taken)
    try await book.plan(1)
    try await book.draft(1)
    try await book.approve(1)
    try await book.finalize(1)
    try await book.draft(2)
    try await book.approve(2)
    try await book.finalize(2)
    await book.expectPlan(.planClaims(chapter: 3, reason: "rise was already reached in chapter 2"), 3, taken)
  }

  @Test func shouldRefuseASecondEnding() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(9, ending: true)
    try await book.plan(9, ending: true)
    let ending = ChapterBook.planEdit(ending: true)
    await book.expectPlan(.endingPlanned(9), 4, ending)
    await book.expectPlan(.endingPlanned(9), 12, ending)
  }

  @Test func shouldRefuseAPlanThatRevealsALockedFactAndAgreeWithTheDerivedVerdict() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let early = ChapterBook.planEdit(learns: [reveal("mara", "tide")])
    await book.expectPlan(.planRevealsLocked(chapter: 2, violations: "tide (needs chapter 5 or later)"), 2, early)
    try await book.plan(5, learns: [reveal("mara", "tide")])
    #expect(try await PlanWorldTables.verdicts(novel, in: book.store)[5] == Verdict(.holds))
  }
}
