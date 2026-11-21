import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Hand-off: asking for a job without starting it", TestTimeLimit.quick)
struct HandOffRequestTests {
  private static func generationRefusal(_ body: () async throws(GenerationRequestError) -> JobKey) async -> String? {
    do throws(GenerationRequestError) {
      _ = try await body()
      return nil
    } catch {
      return error.code
    }
  }

  @Test func shouldAskForAGenerateBehindTheGatesOfGenerateChapterAndStartNothing() async throws {
    let world = try await HandOffWorld.make([.phone], seed: 0x4871)
    let phone = world[0]
    let engine = try phone.engine
    let (novel, chapter) = (ChapterReplicas.novel, ChapterStage.chapter)
    let missing = GenerationRequestError.planMissing.code
    #expect(await Self.generationRefusal { () throws(GenerationRequestError) in try await engine.requestGeneration(novel: novel, chapter: chapter) } == missing)
    try await world.handOff(.plan, worker: 0)
    let sent = phone.model.requests

    let key = try await engine.requestGeneration(novel: novel, chapter: chapter)
    #expect(try await phone.attempts(key.ref).isEmpty && phone.model.requests == sent)
    #expect(try await phone.placement(of: key.ref).map { if case .queued = $0 { true } else { false } } == true)
    let running = GenerationRequestError.generationRunning.code
    #expect(await Self.generationRefusal { () throws(GenerationRequestError) in try await engine.requestGeneration(novel: novel, chapter: chapter) } == running)
    #expect(
      await Self.generationRefusal { () throws(GenerationRequestError) in try await engine.requestGeneration(novel: novel, chapter: chapter, regenerating: true) }
        == running)

    phone.model.queue(ChapterStage.generate.calls())
    #expect(await (try await engine.run(job: key.ref)).result == .settled(.succeeded))
    let drafted = GenerationRequestError.draftExists(chapter).code
    #expect(await Self.generationRefusal { () throws(GenerationRequestError) in try await engine.requestGeneration(novel: novel, chapter: chapter) } == drafted)
    let again = try await engine.requestGeneration(novel: novel, chapter: chapter, regenerating: true)
    #expect(again.run == key.run + 1)
    #expect(try await phone.attempts(again.ref).isEmpty)
  }

  @Test func shouldAskForAModelReviewWithoutStartingItAndAnswerAQuickReviewAtOnce() async throws {
    let world = try await HandOffWorld.make([.phone], seed: 0x4873)
    let phone = world[0]
    let engine = try phone.engine
    let (novel, chapter) = (ChapterReplicas.novel, ChapterStage.chapter)
    try await world.handOff(.plan, worker: 0)
    _ = try await phone.run(.generate)
    let sent = phone.model.requests

    guard case .requested(let key) = try await engine.queueReview(novel: novel, chapter: chapter, kind: .judge) else {
      throw EngineFixtureError(description: "a judge review answered at once")
    }
    #expect(try await engine.queueReview(novel: novel, chapter: chapter, kind: .judge) == .requested(key), "asking again answers the same job")
    #expect(try await phone.attempts(key.ref).isEmpty && phone.model.requests == sent)
    guard case .reviewed(let review) = try await engine.queueReview(novel: novel, chapter: chapter, kind: .mechanics) else {
      throw EngineFixtureError(description: "a mechanics review was asked for as a job")
    }
    let reviews = try await phone.store.chapterReviews(novel: novel, chapter: chapter)
    #expect((reviews.latest + reviews.history).contains { $0.review.id == review } && phone.model.requests == sent)
  }
}
