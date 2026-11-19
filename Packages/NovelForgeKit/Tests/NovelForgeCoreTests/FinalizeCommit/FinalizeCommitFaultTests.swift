import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private func fault(_ table: String, key: String) -> String {
  "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES ('\(table)', '\(key)', 1, 'x')"
}

/// Chapter 1 planned to teach mara heir, drafted, approved and its review read.
private func planned() async throws -> (book: ChapterBook, approval: UUID) {
  let book = try await ChapterBook.make()
  try await book.plan(1, learns: [reveal("mara", "heir")])
  try await book.draft(1)
  let approval = try await book.approve(1)
  try await book.reviewRead(1)
  return (book, approval)
}

/// What the commit reads through derived rows or freezes, failing closed where readiness lets an entry pass.
@Suite("Finalize commit over unreadable or faulted inputs", TestTimeLimit.standard)
struct FinalizeCommitFaultTests {
  // B1: an unreadable learner is left out of the ledger; freezing that would lose the pair for good once the record reads again
  @Test func shouldRefuseWhileALearnerOrFactThePlanTeachesCannotBeReadAndCommitItOnceRepaired() async throws {
    let (book, _) = try await planned()
    let novel = book.novel
    let mara = EntityRecord.ref(novel: novel, entity: "mara")
    try await book.run { transaction in _ = try transaction.set(mara, [EntityField.type.rawValue: .int(5)]) }
    await book.expect(.unreadable(mara), book.commit(1))
    let heir = SecretRecord.ref(novel: novel, secret: "heir")
    try await book.run { transaction in
      _ = try transaction.set(mara, [EntityField.type.rawValue: StoredEnum.known(EntityType.character).json])
      _ = try transaction.set(heir, [SecretField.revealChapter.rawValue: .string("soon")])
    }
    // the lifecycle reads the plan world over the unreadable secret first, which takes the approval out of force
    await book.expect(.draftNotApproved(1), book.commit(1))
    #expect(try await book.final(1) == nil)
    try await book.run { transaction in _ = try transaction.set(heir, [SecretField.revealChapter.rawValue: .int(1)]) }
    try await book.run(book.commit(1))
    #expect(try await book.final(1)?.canon.knowledge == [reveal("mara", "heir")])
    #expect(try await ChapterTables.knowledge(novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
  }

  @Test func shouldCommitAChapterWithoutAPlanWhateverItsLearnersRead() async throws {
    let book = try await ChapterBook.make()
    let mara = EntityRecord.ref(novel: book.novel, entity: "mara")
    try await book.draft(1)
    try await book.approve(1)
    try await book.reviewRead(1)
    try await book.run { transaction in _ = try transaction.set(mara, [EntityField.type.rawValue: .int(5)]) }
    #expect(try await book.run(book.commit(1)) == 1)
  }

  // CharacterKnowledgeDerivation reads manual reveals through the record index
  @Test func shouldRefuseAFaultedIndexEntryOfAManualRevealOfTheNovel() async throws {
    let (book, _) = try await planned()
    let novel = book.novel
    try await book.run { transaction in try ChapterWrites.reveal(novel: novel, fact: "tide", entity: "mara", chapter: 7, in: &transaction) }
    let key = ProjectionFaults.key(CharacterKnowledgeRecord.ref(novel: novel, fact: "tide", entity: "mara"))
    try await book.tamper(fault(IndexedRecord.databaseTableName, key: key))
    await book.expect(.lifecycleUnavailable(1), book.commit(1))
  }

  @Test func shouldLeaveAFaultedIndexEntryOfAnotherKindToTheGuardsThatReadIt() async throws {
    let (book, _) = try await planned()
    let key = ProjectionFaults.key(ThreadRecord.ref(novel: book.novel, thread: "ember"))
    try await book.tamper(fault(IndexedRecord.databaseTableName, key: key))
    #expect(try await book.store.write(book.commit(1)) == 1)
  }

  // M12
  @Test func shouldRefuseAFaultedApprovalEntry() async throws {
    let (book, approval) = try await planned()
    try await book.tamper(fault(ChapterApprovalEntry.databaseTableName, key: ProjectionFaults.key(ApprovalRecord.ref(approval))))
    await book.expect(.lifecycleUnavailable(1), book.commit(1))
  }

  // M13
  @Test func shouldRefuseWhileTheNovelsLedgerIsFaulted() async throws {
    let (book, _) = try await planned()
    try await book.tamper(fault(CharacterKnowledgeEntry.databaseTableName, key: ProjectionFaults.key(book.novel)))
    await book.expect(.lifecycleUnavailable(1), book.commit(1))
  }

  // M5
  @Test func shouldRefuseAReviewOfTheChapterWhoseKindCannotBeRead() async throws {
    let (book, _) = try await planned()
    let novel = book.novel
    let review = ChapterReviewRecord.ref(UUID())
    try await book.run { transaction in _ = try transaction.append(review, item: ["novel": novel.json, "chapter": .int(1), "kind": .int(3)]) }
    await book.expect(.unreadable(review), book.commit(1))
  }

  @Test func shouldCommitOverAnUnreadableReviewThatIsNotAJudgeReview() async throws {
    let (book, _) = try await planned()
    let novel = book.novel
    try await book.run { transaction in
      _ = try transaction.append(ChapterReviewRecord.ref(UUID()), item: ["novel": novel.json, "chapter": .int(1), "kind": .string("editorial")])
    }
    #expect(try await book.run(book.commit(1)) == 1)
  }

  // M18 (provisional-knowledge.ts:171-173): only the rows bound to the finalized revision are committed
  @Test func shouldFreezeOnlyTheLedgerRowsOfTheFinalizedRevision() async throws {
    let (book, _) = try await planned()
    let novel = book.novel
    try await book.tamper(
      "INSERT INTO \(CharacterKnowledgeEntry.databaseTableName) (novel, fact, entity, chapter, source, status, draft) VALUES (X'\(hex(novel))', 'tide', 'mara', 1, 'brief', 'provisional', 'v:elsewhere')"
    )
    try await book.run(book.commit(1))
    #expect(try await book.final(1)?.canon.knowledge == [reveal("mara", "heir")])
  }

  private func hex(_ id: UUID) -> String {
    withUnsafeBytes(of: id.uuid) { bytes in bytes.map { String(format: "%02X", $0) }.joined() }
  }
}

/// Decision 2 on the card path: a card's finalize refused FRV_002 asks for the read it waits on, so a later card can finalize.
@Suite("Finalize from a chat card without a review", TestTimeLimit.standard)
struct FinalizeCardReviewRequestTests {
  @Test func shouldRequestTheMissingReviewWhenTheCardsFinalizeRefuses() async throws {
    let book = try await StagingWorld.workspace()
    let novel = book.novel
    try await book.run { transaction in try ChapterWrites.approve(novel: novel, chapter: 3, in: &transaction) }
    #expect(try await book.store.finalizeReviewJob(novel: novel, chapter: 3) == nil)
    let id = try await book.stage(ApplyWorld.finalize3).proposal.id
    let failure = try #require(try await book.applied(id, .indexes([0])).first?.failure)
    #expect(failure.code == "FRV_002" && failure.message.contains("being prepared"))
    #expect(try await book.store.finalizeReviewJob(novel: novel, chapter: 3) != nil)
  }
}
