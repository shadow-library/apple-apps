import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

/// A working copy held over a revision another device has since replaced is kept as a version, never lost to the next write.
@Suite("Working copies over a replaced head", .timeLimit(.minutes(2)))
struct WorkingCopyPreservationTests {
  /// Chapter 1 drafted, "AB unsynced" held over it, then another device's revision made the head; returns (held over, the other's head).
  private func orphaned(_ book: ChapterBook) async throws -> (String, String) {
    let novel = book.novel
    let first = try await book.draft(1, "A")
    #expect(try await book.save(1, "AB unsynced", base: first) == .held(base: first))
    let other = try await book.run { try ChapterWrites.draft(novel: novel, chapter: 1, body: "Theirs.", source: .generated, in: &$0) }
    return (first, other)
  }

  private func expectKept(_ book: ChapterBook, over first: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let history = try #require(try await book.history(1), sourceLocation: sourceLocation)
    let kept = history.revisions.filter { $0.body.body?.body == "AB unsynced" }
    #expect(kept.map(\.parent) == [first], sourceLocation: sourceLocation)
    #expect(kept.first?.id != history.head, sourceLocation: sourceLocation)
    #expect(try await book.workingCopy(1) == nil, sourceLocation: sourceLocation)
  }

  @Test func shouldKeepTheTextAsAVersionWhenTheEditorReloadsOnTheOtherHeadAndSavesAgain() async throws {
    let book = try await ChapterBook.make()
    let (first, other) = try await orphaned(book)
    let (novel, now) = (book.novel, book.clock.now)
    await book.expect(.draftConflict(chapter: 1, head: other)) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "x"), base: first, at: now, in: &$0) }
    #expect(try await book.workingCopy(1)?.content.body == "AB unsynced")
    guard case .committed(let mine) = try await book.save(1, "Mine.", base: other) else { throw ChapterBookError.notCommitted }
    try await expectKept(book, over: first)
    let history = try #require(try await book.history(1))
    #expect(history.head == mine)
    #expect(history.headEntry?.parent == other)
    #expect(try await book.draftContent(1)?.body == "Mine.")
  }

  @Test func shouldKeepTheTextAsAVersionBeforeAnImportOverTheOtherHead() async throws {
    let book = try await ChapterBook.make()
    let (first, other) = try await orphaned(book)
    let novel = book.novel
    _ = try await book.run { try ChapterDrafts.importDraft(novel: novel, chapter: 1, DraftImport(prose: "Pasted."), base: other, in: &$0) }
    try await expectKept(book, over: first)
    #expect(try await book.history(1)?.headEntry?.parent == other)
    #expect(try await book.draftContent(1)?.body == "Pasted.")
  }

  @Test func shouldKeepTheTextAsAVersionBeforeARestoreOverTheOtherHead() async throws {
    let book = try await ChapterBook.make()
    let (first, other) = try await orphaned(book)
    let novel = book.novel
    _ = try await book.run { try DraftVersions.restore(novel: novel, chapter: 1, revision: first, base: other, in: &$0) }
    try await expectKept(book, over: first)
    #expect(try await book.draftContent(1)?.body == "A")
  }

  @Test func shouldKeepTheTextAsAVersionWhenARemovedDraftIsStartedAgain() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let first = try await book.draft(1, "A")
    try await book.save(1, "AB unsynced", base: first)
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    try await book.save(1, "Again.", base: nil)
    try await expectKept(book, over: first)
    #expect(try await book.draftContent(1)?.body == "Again.")
  }

  @Test func shouldDropAWorkingCopyOnlyWhenItIsDiscarded() async throws {
    let book = try await ChapterBook.make()
    let (first, _) = try await orphaned(book)
    let novel = book.novel
    try await book.run { try ChapterDrafts.discardWorkingCopy(novel: novel, chapter: 1, in: $0) }
    #expect(try await book.history(1)?.revisions.contains { $0.body.body?.body == "AB unsynced" } == false)
    #expect(try await book.history(1)?.revisions.contains { $0.id == first } == true)
  }
}

/// Guards that read derived rows refuse when those rows cannot be trusted.
@Suite("Chapter guards over missing or faulted derived rows", .timeLimit(.minutes(2)))
struct DerivedRowGuardTests {
  private static func fault(_ table: String, key: String = ProjectionFaults.wholeDerivation) -> String {
    "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES ('\(table)', '\(key)', 1, 'probe')"
  }

  private static func entityFault(_ table: String, _ ref: EntityRef) -> String {
    fault(table, key: ProjectionFaults.key(ref))
  }

  @Test func shouldLeavePlanWritesAloneForFaultsOnEntitiesThatCannotChangeThePlanWorld() async throws {
    let book = try await ChapterBook.make()
    let (novel, other) = (book.novel, SchemaFixture.otherNovel)
    try await book.run { transaction in
      try PlanWorldWrites.secret(novel: other, "heir", revealChapter: 1, in: &transaction)
      try PlanWorldWrites.putPlan(novel: other, chapter: 1, planContent(contract()), in: &transaction)
    }
    let unrelated = [
      SecretRecord.ref(novel: other, secret: "heir"), NotebookEntryRecord.ref(UUID()), PageRecord.ref(novel: novel, section: .world, slug: "harbour"),
      try DraftRecord.ref(novel: novel, chapter: 1),
    ]
    for ref in unrelated { try await book.tamper(Self.entityFault(IndexedRecord.databaseTableName, ref)) }
    try await book.tamper(Self.entityFault(ChapterContractEntry.databaseTableName, try ChapterPlanRecord.ref(novel: other, chapter: 1)))
    _ = try await book.store.write { try ChapterPlans.write(novel: novel, chapter: 1, PlanEdit(body: "Accepted."), in: &$0) }
    #expect(try await book.planContent(1)?.body == "Accepted.")
  }

  @Test func shouldRefuseAPlanWhileAFaultCanChangeThisNovelsPlanWorld() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.tamper(Self.entityFault(IndexedRecord.databaseTableName, SecretRecord.ref(novel: novel, secret: "heir")))
    await book.expectPlan(.planStateUnavailable(2), 2, PlanEdit(body: "x"))
    let planned = try await ChapterBook.make()
    try await planned.plan(1)
    try await planned.tamper(Self.entityFault(ChapterContractEntry.databaseTableName, try ChapterPlanRecord.ref(novel: novel, chapter: 1)))
    await planned.expectPlan(.planStateUnavailable(2), 2, PlanEdit(body: "x"))
    let ghost = try await ChapterBook.make()
    try await ghost.tamper(Self.entityFault(IndexedRecord.databaseTableName, SecretRecord.ref(novel: novel, secret: "ghost")))
    await ghost.expectPlan(.planStateUnavailable(2), 2, PlanEdit(body: "x"))
  }

  @Test func shouldRefuseToFinalizeAPlannedChapterWhileAFaultCanChangeWhatItDiscloses() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.plan(1, learns: [KnowledgeReveal(entityKey: "mara", factKey: "heir")])
    try await book.draft(1)
    try await book.approve(1)
    try await book.tamper(Self.entityFault(IndexedRecord.databaseTableName, SecretRecord.ref(novel: novel, secret: "heir")))
    await book.expect(.planStateUnavailable(1)) { try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &$0) }
    #expect(try await book.final(1) == nil)
  }

  @Test func shouldFinalizeAChapterWithoutAPlanWhateverThePlanWorld() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.draft(1)
    try await book.approve(1)
    try await book.tamper(Self.entityFault(IndexedRecord.databaseTableName, SecretRecord.ref(novel: novel, secret: "heir")))
    _ = try await book.store.write { try ChapterFinalize.finalize(novel: novel, chapter: 1, in: &$0) }
    #expect(try await book.final(1)?.canon.disclosed == [])
  }

  @Test func shouldRefuseAPlanWhileAFaultNamesAWatchedEntityWhoseNovelCannotBeRead() async throws {
    let book = try await ChapterBook.make()
    let broken = SecretRecord.ref(novel: SchemaFixture.otherNovel, secret: "broken")
    _ = try await book.store.write { transaction in try transaction.set(broken, [CommonField.removed.rawValue: .bool(false)]) }
    try await book.tamper(Self.entityFault(IndexedRecord.databaseTableName, broken))
    await book.expectPlan(.planStateUnavailable(2), 2, PlanEdit(body: "x"))
  }

  @Test func shouldReadTheKindBackFromAnEntityFaultKey() throws {
    let ref = try DraftRecord.ref(novel: SchemaFixture.novel, chapter: 3)
    #expect(ProjectionFaults.kind(ofKey: ProjectionFaults.key(ref)) == ref.kind)
    #expect(ProjectionFaults.kind(ofKey: ProjectionFaults.key(SchemaFixture.novel)) == nil)
  }

  @Test func shouldRefuseToStartAFinalChapterWhoseDraftWasRemovedWhileTheLifecycleRowsAreMissing() async throws {
    let book = try await ChapterBook.make()
    let (novel, now) = (book.novel, book.clock.now)
    try await book.finalized(through: 1)
    try await book.run { try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &$0) }
    try await book.tamper("DELETE FROM \(ChapterLifecycleEntry.databaseTableName)")
    await book.expect(.draftFinal(1)) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "x"), base: nil, at: now, in: &$0) }
  }

  @Test func shouldRefuseAPlanWhileThePlanWorldRowIsMissingOrFaulted() async throws {
    let book = try await ChapterBook.make()
    try await book.finalized(through: 1)
    try await book.tamper("DELETE FROM \(PlanWorldEntry.databaseTableName)")
    await book.expectPlan(.planStateUnavailable(1), 1, PlanEdit(body: "x"))
    await book.expectPlan(.planStateUnavailable(2), 2, ChapterBook.planEdit(learns: [reveal("mara", "tide")]))
    for table in [PlanWorldEntry.databaseTableName, ChapterContractEntry.databaseTableName, IndexedRecord.databaseTableName] {
      let faulted = try await ChapterBook.make()
      try await faulted.tamper(Self.fault(table))
      await faulted.expectPlan(.planStateUnavailable(1), 1, PlanEdit(body: "x"))
    }
  }

  @Test func shouldRefuseToStartAChapterWhileTheLifecycleIsFaulted() async throws {
    let book = try await ChapterBook.make()
    let (novel, now) = (book.novel, book.clock.now)
    try await book.tamper(Self.fault(ChapterLifecycleEntry.databaseTableName))
    await book.expect(.lifecycleUnavailable(nil)) { try ChapterDrafts.startNext(novel: novel, in: &$0) }
    await book.expect(.lifecycleUnavailable(nil)) { try ChapterDrafts.save(novel: novel, chapter: 1, DraftEdit(body: "x"), base: nil, at: now, in: &$0) }
  }

  @Test func shouldNeverStartADraftOverALiveOneWhenTheLifecycleRowsAreMissing() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    let head = try await book.draft(1, "Kept.")
    try await book.tamper("DELETE FROM \(ChapterLifecycleEntry.databaseTableName)")
    await book.expect(.draftConflict(chapter: 1, head: head)) { try ChapterDrafts.startNext(novel: novel, in: &$0) }
    #expect(try await book.draftContent(1)?.body == "Kept.")
  }
}
