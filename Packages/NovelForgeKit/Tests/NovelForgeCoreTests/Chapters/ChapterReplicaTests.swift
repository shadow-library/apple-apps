import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel

private func book(seed: UInt64) async throws -> CausalReplicas {
  let reconciler = try Projection.reconciler(chapterAreaDerivations)
  let replicas = try await CausalReplicas(
    CausalReplicaSetup(count: 3, registry: Projection.registry, migrations: reconciler.migrations, reconciler: { _ in reconciler }, seed: seed))
  _ = try await replicas.write(0) { transaction in
    try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
    for chapter in 1...2 { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(contract(learns: [Learn("mara", "heir")])), in: &transaction) }
  }
  _ = try await replicas.write(0) { try ChapterWrites.draft(novel: novel, chapter: 1, in: &$0) }
  _ = try await replicas.write(0) { try ChapterWrites.draft(novel: novel, chapter: 2, in: &$0) }
  try await replicas.settle()
  return replicas
}

private func onEach(_ replicas: CausalReplicas) async throws -> [[Int: LifecycleView]] {
  var results = [[Int: LifecycleView]]()
  for index in 0..<replicas.count { results.append(try await ChapterTables.views(novel, in: await replicas.store(index))) }
  return results
}

private func agreed(_ replicas: CausalReplicas) async throws -> [Int: LifecycleView] {
  let results = try await onEach(replicas)
  #expect(Set(results).count == 1)
  return results[0]
}

@Suite("Chapter lifecycle across replicas", TestTimeLimit.standard)
struct ChapterReplicaTests {
  @Test
  func shouldHoldTheLatestOfTwoConcurrentApprovalsOfTheSameHead() async throws {
    let replicas = try await book(seed: 0xD21E)
    let (early, late) = (UUID(), UUID())
    _ = try await replicas.write(1) { try ChapterWrites.approve(novel: novel, chapter: 1, id: early, in: &$0) }
    await replicas.advanceClock(of: 2, by: .seconds(5))
    _ = try await replicas.write(2) { try ChapterWrites.approve(novel: novel, chapter: 1, id: late, in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas)[1] == LifecycleView(review: .approved, approval: late))
  }

  @Test
  func shouldHoldNoApprovalOfAHeadAnotherDeviceRevisedMeanwhile() async throws {
    let replicas = try await book(seed: 0xD21F)
    _ = try await replicas.write(1) { try ChapterWrites.approve(novel: novel, chapter: 1, in: &$0) }
    _ = try await replicas.write(2) { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Rewritten.", source: .handEdited, in: &$0) }
    try await replicas.settle()
    let views = try await agreed(replicas)
    #expect(views[1] == LifecycleView(review: .needsReview))
    #expect(views[2]?.stale == "ancestor chapter 1 was hand_edited")
  }

  @Test
  func shouldMarkADraftAgainWhenAnAncestorChangedWhileAnotherDeviceApprovedItAsWritten() async throws {
    let replicas = try await book(seed: 0xD220)
    _ = try await replicas.write(0) { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Second.", in: &$0) }
    try await replicas.settle()
    _ = try await replicas.write(1) { try ChapterWrites.approve(novel: novel, chapter: 2, kind: .asWritten, in: &$0) }
    #expect(try await ChapterTables.views(novel, in: await replicas.store(1))[2]?.review == .approved)
    _ = try await replicas.write(2) { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Third.", source: .revised, in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas)[2] == LifecycleView(review: .needsReview, stale: "ancestor chapter 1 was revised"))
  }

  @Test
  func shouldMarkWhatRestsOnACanonThatLostAConcurrentFinalize() async throws {
    let replicas = try await book(seed: 0xD221)
    _ = try await replicas.write(2) { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(draftRevision: "v:two", body: "Two.")).finalize(in: &transaction)
    }
    await replicas.advanceClock(of: 1, by: .seconds(5))
    _ = try await replicas.write(1) { transaction in
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: Canon(draftRevision: "v:one", body: "One.")).finalize(in: &transaction)
    }
    _ = try await replicas.write(1) { try ChapterWrites.draft(novel: novel, chapter: 2, body: "On one.", in: &$0) }
    #expect(try await ChapterTables.views(novel, in: await replicas.store(1))[2]?.stale == nil)
    try await replicas.settle()
    let views = try await agreed(replicas)
    #expect(try await ChapterTables.lifecycle(novel, in: await replicas.store(0))[1]?.resting == "v:two")
    #expect(views[1]?.review == .final)
    #expect(views[2]?.stale == "ancestor chapter 1's final text was replaced")
  }
  @Test
  func shouldAgreeOnAHeldRewriteAndOnTheConcurrentWritesThatLiftIt() async throws {
    let replicas = try await book(seed: 0xD230)
    _ = try await replicas.write(1) { try ChapterWrites.rewrite(novel: novel, chapter: 1, holding: true, in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas)[1] == LifecycleView(review: .contradiction))

    let approval = UUID()
    _ = try await replicas.write(1) { try ReviewWrites.judge(novel: novel, chapter: 1, findings: [ReviewWrites.finding("f1")], in: &$0) }
    _ = try await replicas.write(2) { try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas)[1]?.review == .contradiction)

    _ = try await replicas.write(0) { try ChapterWrites.rewrite(novel: novel, chapter: 1, body: "The ledger is forged twice.", holding: true, in: &$0) }
    _ = try await replicas.write(2) { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Rewritten.", source: .handEdited, in: &$0) }
    try await replicas.settle()
    let views = try await agreed(replicas)
    let head = try await replicas.store(0).read { transaction in try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 1), in: transaction).entry?.record }
    #expect(views[1]?.review == (head?.content.source.known == .passageRewritten ? .contradiction : .needsReview))
  }
}
