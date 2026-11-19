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
    _ = try NovelRecord(id: novel, name: "Ember").create(in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
    try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
  }
  _ = try await replicas.write(0) { try ChapterPlans.write(novel: novel, chapter: 1, ChapterBook.planEdit(learns: [reveal("mara", "heir")]), in: &$0) }
  let now = await replicas.store(0).wallClock()
  _ = try await replicas.write(0) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "One.", summary: "Once."), base: nil, at: now, in: &$0) }
  try await replicas.settle()
  return replicas
}

private func head(_ replicas: CausalReplicas, _ index: Int) async throws -> String {
  try await replicas.store(index).read { transaction in
    guard case .revisioned(let state)? = try transaction.state(of: try DraftRecord.ref(novel: novel, chapter: 1)), let head = state.headRevision else { return "" }
    return head
  }
}

private func approve(_ replicas: CausalReplicas, on index: Int, id: UUID) async throws {
  let (revision, requester) = (try await head(replicas, index), await replicas.store(index).replica)
  _ = try await replicas.write(index) { try ChapterApprovals.approve(novel: novel, chapter: 1, revision: revision, id: id, requester: requester, in: &$0) }
}

private func agreed(_ replicas: CausalReplicas) async throws -> LifecycleView? {
  var views = Set<LifecycleView?>()
  for index in 0..<replicas.count { views.insert(try await ChapterTables.views(novel, in: await replicas.store(index))[1]) }
  #expect(views.count == 1)
  return views.first ?? nil
}

@Suite("Chapter operations across replicas", TestTimeLimit.standard)
struct ChapterOperationReplicaTests {
  @Test func shouldHoldTheLaterOfTwoApprovalsOfTheSameHeadMadeOnTwoDevices() async throws {
    let replicas = try await book(seed: 0xD230)
    let (early, late) = (UUID(), UUID())
    try await approve(replicas, on: 1, id: early)
    await replicas.advanceClock(of: 2, by: .seconds(5))
    try await approve(replicas, on: 2, id: late)
    try await replicas.settle()
    #expect(try await agreed(replicas) == LifecycleView(review: .approved, approval: late))
  }

  @Test func shouldNameTheEndingTheDerivationKeepsWhenARefusalFollowsTwoRivalEndings() async throws {
    let replicas = try await book(seed: 0xD232)
    _ = try await replicas.write(1) { try ChapterPlans.write(novel: novel, chapter: 2, ChapterBook.planEdit(ending: true), in: &$0) }
    _ = try await replicas.write(2) { try ChapterPlans.write(novel: novel, chapter: 3, ChapterBook.planEdit(ending: true), in: &$0) }
    try await replicas.settle()
    for index in 0..<replicas.count {
      do {
        _ = try await replicas.write(index) { try ChapterPlans.write(novel: novel, chapter: 4, ChapterBook.planEdit(ending: true), in: &$0) }
        Issue.record("the ending write on replica \(index) was accepted")
      } catch {
        #expect(String(describing: error).contains("Chapter 3 is already planned as the ending"))
      }
    }
  }

  @Test func shouldKeepTheFirstCanonOfAChapterFinalizedOnTwoDevicesAndHideTheOthersAmendment() async throws {
    let replicas = try await book(seed: 0xD231)
    let (first, second) = (UUID(), UUID())
    try await approve(replicas, on: 1, id: first)
    _ = try await replicas.write(1) { try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &$0) }
    await replicas.advanceClock(of: 2, by: .seconds(5))
    try await approve(replicas, on: 2, id: second)
    _ = try await replicas.write(2) { try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &$0) }
    _ = try await replicas.write(2) { try FinalChapters.amend(novel: novel, chapter: 1, ChapterAmendment(content: "Theirs."), in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas)?.review == .final)
    for index in 0..<replicas.count {
      let store = await replicas.store(index)
      #expect(try await Projection.finals(in: store).first?.approval == first)
      let text = try await store.read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record.text.body }
      #expect(text == "One.")
      #expect(try await ChapterTables.knowledge(novel, in: store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    }
    _ = try await replicas.write(2) { try FinalChapters.amend(novel: novel, chapter: 1, ChapterAmendment(content: "Agreed."), in: &$0) }
    try await replicas.settle()
    let amended = try await replicas.store(0).read { try FinalChapterRecord.read(try FinalChapterRecord.ref(novel: novel, chapter: 1), in: $0).entry?.record.text.body }
    #expect(amended == "Agreed.")
  }

  @Test func shouldHoldNoApprovalWhenAnotherDeviceSavedADraftWhileOneApproved() async throws {
    let replicas = try await book(seed: 0xD232)
    try await approve(replicas, on: 1, id: UUID())
    let base = try await head(replicas, 2)
    let now = await replicas.store(2).wallClock()
    let held = try await replicas.write(2) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "Edited elsewhere."), base: base, at: now, in: &$0) }
    #expect(held == .held(base: base))
    _ = try await replicas.write(2) { try ChapterDrafts.commitWorkingCopy(novel: novel, chapter: 1, in: &$0) }
    try await replicas.settle()
    #expect(try await agreed(replicas) == LifecycleView(review: .needsReview))
    let heads = try await [head(replicas, 0), head(replicas, 1), head(replicas, 2)]
    #expect(Set(heads).count == 1 && heads[0] != base)
    do {
      _ = try await replicas.write(1) { try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &$0) }
      Issue.record("finalize succeeded without an approval in force")
    } catch StoreError.aborted(let cause) {
      #expect(cause as? DomainError == .draftNotApproved(1))
    }
  }

  @Test func shouldKeepAWorkingCopyOnTheDeviceThatMadeIt() async throws {
    let replicas = try await book(seed: 0xD233)
    let base = try await head(replicas, 1)
    let now = await replicas.store(1).wallClock()
    let outcome = try await replicas.write(1) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "One, more."), base: base, at: now, in: &$0) }
    #expect(outcome == .held(base: base))
    try await replicas.settle()
    for index in 0..<replicas.count {
      let copy = try await replicas.store(index).read { try DraftWorkingCopy.read(novel: novel, chapter: 1, in: $0.database) }
      #expect((copy != nil) == (index == 1))
    }
  }
}
