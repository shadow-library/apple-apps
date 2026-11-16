import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let milestones = (0..<10).map { "m\($0)" }
private let facts = (0..<20).map { "f\($0)" }

// The whole write with every chapter and plan-world derivation, store and record index included.
private let budget = Duration.milliseconds(25)

#if DEBUG
  private let isRelease = false
#else
  private let isRelease = true
#endif

private func plannedContract(_ chapter: Int, round: Int = 0) -> ChapterContract {
  contract(learns: [Learn("mara", facts[(chapter + round) % facts.count])], claims: [milestones[chapter % milestones.count]], ending: chapter == 200)
}

/// 200 plans, 150 final chapters with 20 KB bodies, a draft with its recorded upstream for every chapter, and approvals of chapters 151 to 170.
private func largeNovel() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations))
  let body = String(repeating: "The tide turns under the old pier. ", count: 600)
  _ = try await Projection.write(store) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
    for key in milestones { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
    for key in facts { try PlanWorldWrites.secret(novel: novel, key, revealChapter: 1, in: &transaction) }
    for chapter in 1...200 {
      let content = ChapterPlanContent(body: body, volume: "one", contract: plannedContract(chapter))
      _ = try ChapterPlanRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction)
    }
    for chapter in 1...200 {
      try ChapterWrites.draft(novel: novel, chapter: chapter, body: body, in: &transaction)
      if chapter <= 170 { try ChapterWrites.approve(novel: novel, chapter: chapter, in: &transaction) }
      if chapter <= 150 { try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction) }
    }
  }
  return store
}

private func median(in store: VaultStore, _ write: @escaping @Sendable (Int, inout WriteTransaction) throws -> Void) async throws -> Duration {
  var durations = [Duration]()
  for round in 0..<9 {
    let start = ContinuousClock.now
    _ = try await Projection.write(store) { transaction in try write(round, &transaction) }
    durations.append(ContinuousClock.now - start)
  }
  return durations.sorted()[durations.count / 2]
}

@Suite("Chapter lifecycle write cost", .serialized, .timeLimit(.minutes(5)))
struct ChapterCostTests {
  @Test(.enabled(if: isRelease, "a time budget holds only for an optimised build: swift test -c release -Xswiftc -enable-testing"))
  func shouldReviseAPlanOrADraftOfALargeNovelWithinTheBudget() async throws {
    let store = try await largeNovel()
    #expect(try await ChapterTables.approvals(novel, in: store).count == 20)
    #expect(try await ChapterTables.knowledge(novel, in: store).count == facts.count)
    let plan = try await median(in: store) { round, transaction in
      let content = planContent(volume: "one", plannedContract(160, round: round + 1))
      _ = try ChapterPlanRecord.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 160), content, in: &transaction)
    }
    let draft = try await median(in: store) { round, transaction in
      try ChapterWrites.draft(novel: novel, chapter: 155, body: "Round \(round).", source: .handEdited, in: &transaction)
    }
    #expect(plan <= budget, "a plan revision took \(plan)")
    #expect(draft <= budget, "a draft revision took \(draft)")
    #expect(try await ChapterTables.views(novel, in: store)[200]?.stale == "ancestor chapter 155 was hand_edited")
  }
}
