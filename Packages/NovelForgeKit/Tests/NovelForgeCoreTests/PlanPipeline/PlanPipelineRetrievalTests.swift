import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Plan pipeline retrieval", TestTimeLimit.standard)
struct PlanPipelineRetrievalTests {
  /// The plan of `planned` names the volume, so the chapter after the final one is planned under its goal.
  private static func world(calls: Int = 1, planned: Int = 2) async throws -> PlanJobWorld {
    try await PlanJobWorld(calls: calls) { novel, transaction in
      _ = try VolumeRecord(novel: novel, volume: "v1", ordinal: 1, title: "One", objective: "Attic\nThe door opens later.", goalMet: false).create(in: &transaction)
      _ = try ChapterPlanRecord(novel: novel, chapter: planned, content: ChapterPlanContent(title: "Next", body: "Mara opens the door.", volume: "v1")).create(in: &transaction)
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(body: "Mara found the lamp in the attic.")).finalize(in: &transaction)
    }
  }

  private static func indexed(_ store: VaultStore) async throws -> Bool {
    try await store.read { transaction in try transaction.database.tableExists(RetrievalTables.source) }
  }

  // context-assembler.service.ts:659-674
  @Test func shouldGiveThePlannerTheProseRetrievalFindsForTheVolumeGoalFromAnIndexItCaughtUp() async throws {
    let world = try await Self.world()
    #expect(try await Self.indexed(world.store) == false)
    let engine = try world.engine()
    let receipt = try await world.request(engine)
    #expect(receipt.chapter == 2)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    let prompt = try #require(world.userPrompt)
    #expect(prompt.contains("## PROSE REFERENCES\n\n1. [Ch 1] Mara found the lamp in the attic."))
  }

  @Test func shouldNotSearchForAnEmptyPlan() async throws {
    let world = try await Self.world(calls: 0, planned: 3)
    let engine = try world.engine()
    let receipt = try await world.request(engine, empty: true)
    #expect(try await engine.run(job: receipt.job.ref).result == .settled(.succeeded))
    #expect(try await Self.indexed(world.store) == false)
  }
}
