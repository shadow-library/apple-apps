import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Generation requests", TestTimeLimit.standard)
struct GenerationRequestTests {
  private static func refusal(_ world: GenerationWorld, chapter: Int = 1, first: Bool = false, unrestrictedAvailable: Bool = false) async throws -> GenerationRequestError? {
    let engine = try world.engine(unrestrictedAvailable: unrestrictedAvailable)
    do {
      _ = first ? try await engine.generateChapter(novel: world.novel, chapter: chapter) : try await engine.regenerateChapter(novel: world.novel, chapter: chapter)
      return nil
    } catch {
      return error
    }
  }

  private static func write(_ world: GenerationWorld, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
    _ = try await Projection.write(world.store) { transaction in try body(&transaction) }
  }

  @Test func shouldRefuseAChapterWithNoPlan() async throws {
    let world = try await GenerationWorld(plan: nil)
    #expect(try await Self.refusal(world)?.code == "BRF_001")
  }

  @Test func shouldRefuseToGenerateAChapterThatAlreadyHasADraft() async throws {
    let world = try await GenerationWorld()
    try await world.handDraft()
    let refusal = try await Self.refusal(world, first: true)
    #expect(refusal?.code == "DRF_015" && refusal?.errorDescription == "Chapter 1 already has a draft — regenerate it from the chapter itself")
  }

  @Test func shouldRefuseAStalePlan() async throws {
    let world = try await GenerationWorld(plan: nil)
    let novel = world.novel
    try await Self.write(world) { transaction in
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 3, in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
    }
    #expect(try await world.lifecycle().planStale != nil)
    #expect(try await Self.refusal(world)?.code == "BRF_002")
  }

  @Test func shouldRefuseAFinalChapter() async throws {
    let world = try await GenerationWorld()
    let novel = world.novel
    try await Self.write(world) { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(draftRevision: "v:draft", body: "Final.")).finalize(in: &transaction)
    }
    #expect(try await Self.refusal(world)?.code == "CHP_008")
  }

  @Test func shouldRefuseWhileAnyGenerateJobOfTheNovelIsOpen() async throws {
    let world = try await GenerationWorld()
    let engine = try world.engine()
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 3, fingerprint: "other"))
    engine.relinquish()
    #expect(try await Self.refusal(world)?.code == "DRF_010")
  }

  @Test func shouldRefuseARerunWhileTheSameRunIsOpen() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), JobEngineWorld.frozen])
    let engine = try world.engine()
    guard case .running(let handle) = try await engine.regenerateChapter(novel: world.novel, chapter: 1) else { throw EngineFixtureError(description: "not run here") }
    try await world.base.waitForRequests(2)
    do {
      _ = try await engine.regenerateChapter(novel: world.novel, chapter: 1)
      Issue.record("a second run started beside the open one")
    } catch {
      #expect(error.code == "DRF_010")
    }
    _ = try await engine.cancel(job: handle.job)
    #expect(await handle.result == .settled(.cancelled))
  }

  @Test func shouldRefuseTheAuthorsOwnDraftWritesWhileTheChapterIsBeingGenerated() async throws {
    let world = try await GenerationWorld()
    let engine = try world.engine()
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "open"))
    engine.relinquish()
    #expect(try await world.lifecycle().review == .generating)
    let novel = world.novel
    let now = world.base.clock.now
    await #expect(throws: DomainError.draftGenerating(1)) {
      _ = try await world.store.writeDomain { transaction throws(DomainError) in
        try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "Mine."), base: nil, at: now, in: &transaction)
      }
    }
    #expect(DomainError.draftGenerating(1).code == "DRF_019")
  }

  @Test func shouldRefuseAHandSaveOverADraftWhileItIsBeingRegenerated() async throws {
    let world = try await GenerationWorld()
    let head = try await world.handDraft()
    let engine = try world.engine()
    _ = try await engine.request(NovelJobRequest(kind: .generate, novel: world.novel, chapter: 1, fingerprint: "open"))
    engine.relinquish()
    let novel = world.novel
    let now = world.base.clock.now
    await #expect(throws: DomainError.draftGenerating(1)) {
      _ = try await world.store.writeDomain { transaction throws(DomainError) in
        try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "Mine."), base: head, at: now, in: &transaction)
      }
    }
    await #expect(throws: DomainError.draftGenerating(1)) {
      _ = try await world.store.writeDomain { transaction throws(DomainError) in
        try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Pasted."), base: head, in: &transaction)
      }
    }
  }

  @Test func shouldRefuseWhileAnotherChapterIsHeldAsAContradiction() async throws {
    let world = try await GenerationWorld()
    let novel = world.novel
    try await Self.write(world) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(pov: [])), in: &transaction)
      let head = try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
      let finding = ReviewFinding(id: "f1", severity: .known(.blocking), category: .known(.continuity), text: "A contradiction.", fingerprint: "fp")
      _ = try ChapterReviewRecord(
        novel: novel, chapter: 2, reviewKind: .known(.judge), draftRevision: head, bodyHash: hashReviewedBody("The tide turns."), disposition: .known(.blocking),
        verdict: "contradiction", findings: [finding]
      ).append(in: &transaction)
    }
    #expect(try await world.lifecycle(2).review == .contradiction)
    #expect(try await Self.refusal(world)?.code == "DRF_003")
  }

  @Test func shouldRefuseAChapterAheadOfTheNextUnwrittenOne() async throws {
    let world = try await GenerationWorld()
    let novel = world.novel
    try await Self.write(world) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(pov: [])), in: &transaction) }
    let refusal = try await Self.refusal(world, chapter: 2)
    #expect(refusal?.code == "DRF_011")
    #expect(refusal?.errorDescription == "Chapter 2 cannot be generated before chapter 1 is drafted — chapters are generated in order")
  }

  @Test func shouldRefuseAChapterBehindAnUnfilledExternalChapter() async throws {
    let world = try await GenerationWorld(plan: GenerationWorld.plan(writeMode: .external))
    let novel = world.novel
    try await Self.write(world) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(pov: [])), in: &transaction) }
    #expect(try await Self.refusal(world, chapter: 2)?.code == "DRF_012")
  }

  @Test func shouldRefuseAChapterAfterAnUnapprovedTeacher() async throws {
    let world = try await GenerationWorld(plan: nil)
    let novel = world.novel
    try await Self.write(world) { transaction in
      try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
      try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction)
      try PlanWorldWrites.putPlan(novel: novel, chapter: 2, planContent(contract(pov: [])), in: &transaction)
      _ = try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    #expect(try await Self.refusal(world, chapter: 2)?.code == "DRF_016")
  }

  @Test func shouldRefuseAnUnrestrictedChapterWhereUnrestrictedWritingIsUnavailable() async throws {
    let world = try await GenerationWorld(plan: GenerationWorld.plan(.unrestricted))
    #expect(try await Self.refusal(world)?.code == "AI_024")
    let novel = world.novel
    let activity = try await world.store.read { transaction in
      try JobActivity.load(JobActivityQuery(novel: novel, now: LeaseInstant(date: EngineClock.epoch, source: .device)), in: transaction).entries.value
    }
    #expect(activity?.isEmpty == true)
  }
}
