import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let milestones = (0..<10).map { "m\($0)" }
private let facts = (0..<20).map { "f\($0)" }

// The whole write, store and record index included, so the plan world's own share is smaller.
private let budget = Duration.milliseconds(15)

#if DEBUG
  private let isRelease = false
#else
  private let isRelease = true
#endif

private func plannedContract(_ chapter: Int) -> ChapterContract {
  contract(learns: [Learn("mara", facts[chapter % facts.count])], claims: [milestones[chapter % milestones.count]], ending: chapter == 200)
}

/// A novel of 200 plans and 150 final chapters with 20 KB bodies, as the review measured it.
private func largeNovel() async throws -> VaultStore {
  let store = try Projection.store(try Projection.reconciler(ProjectionDerivations.all + PlanWorldDerivations.all))
  let body = String(repeating: "The tide turns under the old pier. ", count: 600)
  _ = try await Projection.write(store) { transaction in
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    for key in milestones { try PlanWorldWrites.milestone(novel: novel, key, in: &transaction) }
    for (index, key) in facts.enumerated() {
      try PlanWorldWrites.secret(novel: novel, key, revealChapter: index * 10, unlock: unlock(.milestone(milestones[index % milestones.count])), in: &transaction)
    }
    for chapter in 1...200 {
      let content = ChapterPlanContent(body: body, volume: "one", contract: plannedContract(chapter))
      _ = try ChapterPlanRecord(novel: novel, chapter: chapter, content: content).create(in: &transaction)
    }
    for chapter in 1...150 {
      let canon = Canon(draftRevision: "v:draft", planRevision: "v:plan", body: body, volume: "one", contract: plannedContract(chapter))
      _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction)
    }
  }
  return store
}

private func medianRevision(in store: VaultStore) async throws -> Duration {
  var durations = [Duration]()
  for round in 0..<9 {
    let content = planContent(volume: "one", contract(learns: [Learn("mara", facts[round])], claims: [milestones[round]]))
    let start = ContinuousClock.now
    _ = try await Projection.write(store) { transaction in _ = try ChapterPlanRecord.revise(try ChapterPlanRecord.ref(novel: novel, chapter: 180), content, in: &transaction) }
    durations.append(ContinuousClock.now - start)
  }
  return durations.sorted()[durations.count / 2]
}

@Suite("Plan world write cost", .serialized, .timeLimit(.minutes(5)))
struct PlanWorldCostTests {
  @Test(.enabled(if: isRelease, "a time budget holds only for an optimised build: swift test -c release -Xswiftc -enable-testing"))
  func shouldReviseAPlanOfALargeNovelWithinTheBudget() async throws {
    let store = try await largeNovel()
    let median = try await medianRevision(in: store)
    #expect(median <= budget, "a revision took \(median)")
    #expect(try await PlanWorldTables.verdicts(novel, in: store).count == 200)
  }
}
