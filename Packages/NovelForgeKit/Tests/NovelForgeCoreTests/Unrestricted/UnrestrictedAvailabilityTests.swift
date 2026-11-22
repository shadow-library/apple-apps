import Foundation
import NaturalLanguage
import ShadowAI
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

@Suite("Unrestricted availability", TestTimeLimit.standard)
struct UnrestrictedAvailabilityTests {
  @Test func shouldFollowTheBuildFlag() {
    #if SHADOW_UNRESTRICTED
      #expect(UnrestrictedWriting.isAvailable)
    #else
      #expect(!UnrestrictedWriting.isAvailable)
    #endif
  }

  @Test func shouldKeepTheLatestAnswerOfTheAgeGate() {
    let gate = AgeGate(passed: false)
    #expect(!gate.isPassed)
    gate.update(passed: true)
    #expect(gate.isPassed)
    gate.update(passed: false)
    #expect(!gate.isPassed)
  }

  @Test func shouldLetTheAuthorsApplyAndRevertRaiseOnlyWhenTheBuildAndTheAgeGateBothAllow() {
    let novel = UUID()
    for passed in [false, true] {
      let gate = AgeGate(passed: passed)
      #expect(ProposalApplyContext(novel: novel, now: Date(), ageGate: gate).unrestrictedAvailable == (UnrestrictedWriting.isAvailable && passed))
      #expect(ProposalRevertContext(novel: novel, now: Date(), ageGate: gate).unrestrictedAvailable == (UnrestrictedWriting.isAvailable && passed))
    }
  }

  @Test func shouldWithholdUnrestrictedJobsWhileTheAgeGateIsWithheld() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider())
    let gate = AgeGate(passed: false)
    let engine = try world.engine(unrestrictedAvailable: true, ageGate: gate)
    #expect(!engine.services.unrestrictedAvailable)
    gate.update(passed: true)
    #expect(engine.services.unrestrictedAvailable)
  }

  @Test func shouldNeverMakeUnrestrictedJobsAvailableWhenTheBuildLacksThem() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider())
    let engine = try world.engine(unrestrictedAvailable: false, ageGate: AgeGate(passed: true))
    #expect(!engine.services.unrestrictedAvailable)
  }

  @Test func shouldTakeOnlyTheBuildsFlagThroughThePublicInit() async throws {
    let world = try await JobEngineWorld(provider: ScriptedModelProvider())
    let engine = try JobEngine(
      store: world.store, router: { world.router($0) }, consent: CompactionWorld.consent, clock: LeaseClock(trusted: nil), ageGate: AgeGate(passed: true))
    #expect(engine.services.unrestrictedAvailable == UnrestrictedWriting.isAvailable)
  }

  @Test func shouldRefuseAnUnrestrictedChapterUntilTheAgeGatePassesThenRouteIt() async throws {
    let world = try await GenerationWorld(calls: [GenerationWorld.draftReply(), GenerationWorld.judgeReply()], plan: GenerationWorld.plan(.unrestricted))
    let gate = AgeGate(passed: false)
    let engine = try world.engine(unrestrictedAvailable: true, ageGate: gate)
    var refusal: GenerationRequestError?
    do {
      _ = try await engine.regenerateChapter(novel: world.novel, chapter: 1)
    } catch {
      refusal = error
    }
    #expect(refusal?.code == "AI_024")
    #expect(world.provider.requests.isEmpty)

    gate.update(passed: true)
    let handle = try await world.generate(engine)

    #expect(try await world.saved(handle.job).first?.body.body?.isolated == true)
    #expect(!world.provider.requests.isEmpty && world.provider.requests.allSatisfy { $0.model == CompactionWorld.unrestrictedModel })
  }
}

@Suite("Hard-line coverage", TestTimeLimit.quick)
struct HardLineCoverageTests {
  private static let english = "The lighthouse keeper climbed the stairs every night, counting the steps until the lamp room opened above the sea."
  private static let french = "Le gardien du phare montait l'escalier chaque nuit, en comptant les marches jusqu'à la salle de la lampe au-dessus de la mer."
  private static let mixed = "The keeper climbs the stairs every night to light the lamp above the sea. Le gardien monte l'escalier chaque nuit."

  @Test func shouldCoverEnglishOnly() {
    #expect(HardLineCoverage.covers(.english))
    #expect(!HardLineCoverage.covers(.french))
    #expect(!HardLineCoverage.covers(nil))
  }

  @Test func shouldTellNoLanguageFromAShortOrMixedSample() {
    #expect(HardLineCoverage.language(of: Self.english) == .english)
    #expect(HardLineCoverage.language(of: "Ashfall") == nil)
    #expect(HardLineCoverage.language(of: "The keeper climbs the stairs at night.") == nil)
    #expect(HardLineCoverage.language(of: Self.mixed) == nil)
  }

  @Test func shouldReadTheNovelsLanguageFromItsOwnDescriptionBeforeItIsIndexed() async throws {
    let store = try NovelForgeStore.openInMemory()
    let english = try await novel(in: store, brief: Self.english)
    let french = try await novel(in: store, brief: Self.french)
    let mixed = try await novel(in: store, brief: Self.mixed)
    let titled = try await novel(in: store, title: Self.english, brief: nil)
    let blank = try await novel(in: store, brief: nil)

    let covered = try await store.read { transaction in
      try [english, french, mixed, titled, blank, UUID()].map { novel throws(StoreError) in try HardLineCoverage.covers(novel: novel, in: transaction) }
    }
    #expect(covered == [true, false, false, false, false, false])
  }

  @Test func shouldLetIndexedProseOverrideTheDescription() async throws {
    let world = try RetrievalWorld()
    _ = try await world.store.write { transaction in _ = try NovelRecord(id: world.novel, name: "Phare", brief: Self.english).create(in: &transaction) }
    let novel = world.novel
    let before = try await world.store.read { transaction in try HardLineCoverage.covers(novel: novel, in: transaction) }
    try await world.finalize(1, Self.french)
    try await world.retrieval.catchUp(novel: novel)
    let after = try await world.store.read { transaction in try HardLineCoverage.covers(novel: novel, in: transaction) }
    #expect(before && !after)
  }

  private func novel(in store: VaultStore, title: String? = nil, brief: String?) async throws -> UUID {
    let id = UUID()
    _ = try await store.write { transaction in _ = try NovelRecord(id: id, name: title ?? "", title: title, brief: brief).create(in: &transaction) }
    return id
  }
}
