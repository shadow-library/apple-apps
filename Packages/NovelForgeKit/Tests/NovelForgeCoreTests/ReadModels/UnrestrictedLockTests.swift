import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

private let novel = ChatWorld.novel
private let otherNovel = ChatWorld.otherNovel

private func store() throws -> VaultStore {
  try Projection.store(try ChatWorld.reconciler(), allowingFaults: true)
}

private func draft(_ chapter: Int, novel: UUID = novel, generator: ContentGenerator = .standard, isolated: Bool = false) -> DraftContent {
  DraftContent(body: "Chapter \(chapter).", source: .known(.generated), generator: .known(generator), isolated: isolated)
}

private func write(_ revisions: [DraftContent], chapter: Int, novel: UUID = novel, in store: VaultStore) async throws {
  _ = try await Projection.write(store) { transaction in
    let record = try DraftRecord(novel: novel, chapter: chapter, content: revisions[0])
    _ = try record.create(in: &transaction)
    for content in revisions.dropFirst() { _ = try DraftRecord.revise(record.ref, content, in: &transaction) }
  }
}

private func finalize(_ chapter: Int, generator: ContentGenerator = .standard, isolated: Bool = false, in store: VaultStore) async throws {
  let canon = Canon(body: "Final \(chapter).", generator: .known(generator), isolated: isolated)
  _ = try await Projection.write(store) { transaction in _ = try FinalChapterRecord(novel: novel, chapter: chapter, canon: canon).finalize(in: &transaction) }
}

private func fault(_ table: String, _ key: String, in store: VaultStore) async throws {
  try await ReadWorld.insertFault(table, key: key, in: store)
}

private func loadLock(_ novel: UUID = novel, in store: VaultStore) async throws -> UnrestrictedLock {
  try await store.load(UnrestrictedLock.self, novel)
}

@Suite("Unrestricted lock", TestTimeLimit.standard)
struct UnrestrictedLockTests {
  @Test func shouldStayOpenWhileTheNovelHoldsOnlyStandardText() async throws {
    let store = try store()
    try await ChatWorld.createSession(in: store)
    try await ChatWorld.append(try ChatWorld.message(mode: .standard), in: store)
    try await write([draft(1), draft(1, generator: .human)], chapter: 1, in: store)
    try await finalize(1, in: store)
    let lock = try await loadLock(in: store)
    #expect(lock.holders == .available([]) && !lock.isLocked)
  }

  @Test func shouldLockOnAChatThatHoldsUnrestrictedText() async throws {
    let store = try store()
    try await ChatWorld.createSession(in: store)
    try await ChatWorld.append(try ChatWorld.message(mode: .unrestricted), in: store)
    let lock = try await loadLock(in: store)
    #expect(lock.holders == .available([.chats]) && lock.isLocked)
    #expect(try await loadLock(otherNovel, in: store).holders == .available([]))
  }

  @Test func shouldLockOnAnUnrestrictedDraftRevisionOffTheHeadOrInARemovedDraft() async throws {
    let store = try store()
    try await write([draft(2, generator: .unrestricted, isolated: true), draft(2)], chapter: 2, in: store)
    try await write([draft(4, isolated: true)], chapter: 4, in: store)
    _ = try await Projection.write(store) { transaction in try ChapterWrites.removeDraft(novel: novel, chapter: 4, in: &transaction) }
    try await write([draft(5, generator: .unrestricted, isolated: true)], chapter: 5, novel: otherNovel, in: store)
    let lock = try await loadLock(in: store)
    #expect(lock.holders == .available([.draft(chapter: 2), .draft(chapter: 4)]) && lock.isLocked)
  }

  @Test func shouldLockOnUnrestrictedOrIsolatedCanon() async throws {
    let store = try store()
    try await finalize(1, generator: .unrestricted, in: store)
    try await finalize(2, isolated: true, in: store)
    try await finalize(3, in: store)
    #expect(try await loadLock(in: store).holders == .available([.canon(chapter: 1), .canon(chapter: 2)]))
  }

  @Test func shouldCountTextThisVersionCannotReadAsHolding() async throws {
    let store = try store()
    var future = draft(1)
    future.generator = .unknown("future")
    try await write([future], chapter: 1, in: store)
    try await write([draft(2)], chapter: 2, in: store)
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.revise(try DraftRecord.ref(novel: novel, chapter: 2), body: ["body": 3], parent: .head, head: false, marks: [])
    }
    #expect(try await loadLock(in: store).holders == .available([.draft(chapter: 1), .draft(chapter: 2)]))
  }

  @Test func shouldLockEveryNovelOnAnUnrestrictedDraftWhoseKeyCannotBeRead() async throws {
    let store = try store()
    let ref = try DraftRecord.ref(novel: novel, chapter: 7)
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.set(ref, [CommonField.naturalKey.rawValue: ["novel": novel.json, "chapter": "one"]])
      _ = try transaction.revise(ref, body: draft(7, isolated: true).json)
    }
    #expect(try await loadLock(in: store).holders == .available([.draft(chapter: nil)]))
    #expect(try await loadLock(otherNovel, in: store).holders == .available([.draft(chapter: nil)]))
  }

  @Test func shouldLockOnACanonThisVersionCannotRead() async throws {
    let store = try store()
    let key = try NovelForgeKey.finalChapterKey(novel: novel, chapter: 3)
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.set(key.ref, [CommonField.naturalKey.rawValue: key.stored, FinalChapterField.canon.rawValue: ["body": 3]])
    }
    #expect(try await loadLock(in: store).holders == .available([.canon(chapter: 3)]))
  }

  @Test func shouldLockOnReviewsOfIsolatedProseOnly() async throws {
    let store = try store()
    var generator = SeededGenerator(seed: 18)
    let reviews = try [false, true].map { isolated in
      try ChapterReviewRecord(
        novel: novel, chapter: isolated ? 2 : 1, reviewKind: .known(.judge), draftRevision: nil, bodyHash: "h", disposition: .known(.clear), isolated: isolated)
    }
    let finalizeReviews = try [false, true].map { isolated in
      try FinalizeReviewRecord(
        attempt: Gen.attempt(&generator), job: Gen.jobKey(&generator), novel: novel, chapter: isolated ? 4 : 3, draftRevision: "r", sourceHash: "h", planHash: nil,
        isolated: isolated, items: [])
    }
    _ = try await Projection.write(store) { transaction in
      for review in reviews { _ = try review.append(in: &transaction) }
      for review in finalizeReviews { _ = try review.append(in: &transaction) }
    }
    #expect(try await loadLock(in: store).holders == .available([.chapterReview(chapter: 2), .finalizeReview(chapter: 4)]))
  }

  @Test func shouldCountAChapterReviewThisVersionCannotReadAsHolding() async throws {
    let store = try store()
    _ = try await Projection.write(store) { transaction in
      _ = try transaction.append(NovelForgeKey.chapterReview(UUID()), item: ["novel": novel.json, "chapter": 5, "isolated": "maybe"])
    }
    #expect(try await loadLock(in: store).holders == .available([.chapterReview(chapter: 5)]))
  }

  @Test func shouldBlockOnAFaultedChapterReviewOfThisNovelOnly() async throws {
    for (owner, locked) in [(novel, true), (otherNovel, false)] {
      let store = try store()
      let review = try ChapterReviewRecord(
        novel: owner, chapter: 1, reviewKind: .known(.judge), draftRevision: nil, bodyHash: "h", disposition: .known(.clear), isolated: false)
      _ = try await Projection.write(store) { transaction in _ = try review.append(in: &transaction) }
      try await fault(IndexedRecord.databaseTableName, ProjectionFaults.key(review.ref), in: store)
      let lock = try await loadLock(in: store)
      #expect(lock.holders.isUnavailable == locked && lock.isLocked == locked, "\(owner)")
    }
  }

  @Test func shouldTreatAFaultThatCouldHideAHolderAsLocked() async throws {
    let draftKey = ProjectionFaults.key(try DraftRecord.ref(novel: novel, chapter: 1))
    let canonKey = ProjectionFaults.key(try FinalChapterRecord.ref(novel: novel, chapter: 1))
    let cases: [(String, String)] = [
      (IndexedRecord.databaseTableName, ProjectionFaults.wholeDerivation), (IndexedRecord.databaseTableName, String(reflecting: novel)),
      (IndexedRecord.databaseTableName, draftKey), (IndexedRecord.databaseTableName, canonKey), (IndexedRecord.databaseTableName, "unparsed key"),
      (ChatMessageRow.databaseTableName, ProjectionFaults.key(NovelForgeKey.chatMessage(UUID()))),
      (ChatSessionState.databaseTableName, ProjectionFaults.wholeDerivation),
    ]
    for (table, key) in cases {
      let store = try store()
      try await write([draft(1)], chapter: 1, in: store)
      try await finalize(1, in: store)
      try await fault(table, key, in: store)
      let lock = try await loadLock(in: store)
      #expect(lock.holders.isUnavailable && lock.isLocked && !lock.faults.isEmpty, "\(table) \(key)")
    }
  }

  @Test func shouldIgnoreAFaultThatCannotHideAHolderOfThisNovel() async throws {
    let store = try store()
    try await write([draft(1)], chapter: 1, in: store)
    try await write([draft(1)], chapter: 1, novel: otherNovel, in: store)
    try await fault(IndexedRecord.databaseTableName, ProjectionFaults.key(try DraftRecord.ref(novel: otherNovel, chapter: 1)), in: store)
    try await fault(IndexedRecord.databaseTableName, ProjectionFaults.key(try ChapterPlanRecord.ref(novel: novel, chapter: 1)), in: store)
    try await fault(IndexedRecord.databaseTableName, String(reflecting: otherNovel), in: store)
    let lock = try await loadLock(in: store)
    #expect(lock.holders == .available([]) && !lock.isLocked && lock.faults.isEmpty)
  }
}
