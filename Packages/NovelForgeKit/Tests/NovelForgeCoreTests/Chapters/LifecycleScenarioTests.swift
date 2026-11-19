import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

private let novel = SchemaFixture.novel
private let teachesHeir = contract(learns: [Learn("mara", "heir")])
private let teachesTide = contract(learns: [Learn("mara", "tide")])

private func store() throws -> VaultStore {
  try Projection.store(try Projection.reconciler(chapterAreaDerivations))
}

private func write(_ store: VaultStore, _ body: @escaping @Sendable (inout WriteTransaction) throws -> Void) async throws {
  _ = try await Projection.write(store) { transaction in try body(&transaction) }
}

/// Secrets `heir` and `tide` shown from chapter 1, the learner `mara`, and plans for chapters 1 to 3 that teach `heir`.
private func seeded() async throws -> VaultStore {
  let store = try store()
  try await write(store) { transaction in
    try PlanWorldWrites.secret(novel: novel, "heir", revealChapter: 1, in: &transaction)
    try PlanWorldWrites.secret(novel: novel, "tide", revealChapter: 1, in: &transaction)
    try PlanWorldWrites.milestone(novel: novel, "rise", in: &transaction)
    try ChapterWrites.entity(novel: novel, "mara", in: &transaction)
    for chapter in 1...3 { try PlanWorldWrites.putPlan(novel: novel, chapter: chapter, planContent(teachesHeir), in: &transaction) }
  }
  return store
}

private func views(_ store: VaultStore) async throws -> [Int: LifecycleView] {
  try await ChapterTables.views(novel, in: store)
}

private func stale(_ store: VaultStore, _ chapter: Int) async throws -> String? {
  try await views(store)[chapter]?.stale
}

@Suite("Chapter lifecycle", TestTimeLimit.standard)
struct LifecycleScenarioTests {
  @Test func shouldHoldAnApprovalOfTheHeadUnderTheCurrentPlanTerms() async throws {
    let store = try await seeded()
    let approval = UUID()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await views(store)[1] == LifecycleView(review: .needsReview))
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: approval, in: &transaction) }
    #expect(try await views(store)[1] == LifecycleView(review: .approved, approval: approval))
    #expect(try await ChapterTables.approvals(novel, in: store) == [1: approval])
    #expect(try await views(store)[2] == LifecycleView(review: nil))
  }

  @Test func shouldDropAnApprovalWhenTheDraftIsRevisedAndNeverRestoreItForTheOldHead() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Rewritten.", source: .handEdited, in: &transaction) }
    #expect(try await views(store)[1] == LifecycleView(review: .needsReview))
    #expect(try await ChapterTables.approvals(novel, in: store).isEmpty)
  }

  @Test func shouldHoldAnApprovalOfAChapterWithoutAPlanUnderEmptyTerms() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 4, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 4, in: &transaction)
    }
    #expect(try await views(store)[4]?.review == .approved)
    try await write(store) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 4, planContent(contract()), in: &transaction) }
    #expect(try await views(store)[4]?.review == .approved)
    try await write(store) { transaction in _ = try ChapterPlanRecord.remove(try ChapterPlanRecord.ref(novel: novel, chapter: 1), in: &transaction) }
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    #expect(try await views(store)[1]?.review == .approved)
  }

  @Test func shouldTakeTheLatestOfTwoApprovalsOfTheHead() async throws {
    let store = try await seeded()
    let (first, second) = (UUID(), UUID())
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, id: first, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, id: second, in: &transaction) }
    #expect(try await views(store)[1]?.approval == second)
  }

  @Test func shouldResetAnApprovalOnAMilestoneChangeWithoutMarkingLaterDrafts() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction) }
    try await write(store) { transaction in
      try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "heir")], claims: ["rise"])), in: &transaction)
    }
    #expect(try await views(store)[1] == LifecycleView(review: .needsReview))
    #expect(try await stale(store, 2) == nil)
  }

  @Test func shouldMarkLaterDraftsWhenAnApprovedPlanChangesWhatItsCastLearns() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 2, in: &transaction)
    }
    try await write(store) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(teachesTide), in: &transaction) }
    #expect(try await stale(store, 2) == "ancestor chapter 1's plan changed what its cast learns after approval")
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await stale(store, 2) == "ancestor chapter 1's plan changed what its cast learns after approval")
    #expect(try await views(store)[2]?.review == .needsReview)
  }

  @Test func shouldNeverMarkADraftBecauseAnEarlierChapterWasApprovedAfterIt() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await stale(store, 2) == nil)
  }

  @Test func shouldMarkEveryLaterDraftWithTheLowestAncestorThatChanged() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      for chapter in 1...3 { try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction) }
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, body: "Again.", source: .chatEdited, in: &transaction) }
    #expect(try await stale(store, 3) == "ancestor chapter 2 was chat_edited")
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Again.", source: .restored, in: &transaction) }
    let after = try await views(store)
    #expect(after[2]?.stale == "ancestor chapter 1 was restored to an earlier version")
    #expect(after[3]?.stale == "ancestor chapter 1 was restored to an earlier version")
    try await write(store) { transaction in try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await stale(store, 3) == "ancestor chapter 1 was removed")
  }

  @Test func shouldClearAMarkWhenTheDraftIsWrittenAgainstTheCurrentChapters() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    #expect(try await stale(store, 2) == "ancestor chapter 1 was drafted")
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, body: "Again.", in: &transaction) }
    #expect(try await stale(store, 2) == nil)
  }

  @Test func shouldAcceptTheDifferencesAnAsWrittenApprovalRecordedAndNoLaterOnes() async throws {
    let store = try await seeded()
    let approval = UUID()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Again.", in: &transaction) }
    #expect(try await stale(store, 2) == "ancestor chapter 1 was regenerated")
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, kind: .asWritten, id: approval, in: &transaction) }
    #expect(try await views(store)[2] == LifecycleView(review: .approved, approval: approval))
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Once more.", source: .revised, in: &transaction) }
    #expect(try await views(store)[2] == LifecycleView(review: .needsReview, stale: "ancestor chapter 1 was revised"))
  }

  @Test func shouldNeverAcceptAStandardApprovalOfAStaleDraft() async throws {
    let store = try await seeded()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, recording: .none, in: &transaction) }
    #expect(try await stale(store, 2) == "the draft does not record what it was written against")
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, in: &transaction) }
    #expect(try await views(store)[2]?.review == .needsReview)
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, kind: .asWritten, in: &transaction) }
    #expect(try await views(store)[2]?.review == .approved)
  }

  @Test func shouldMarkAPlanAndItsDraftWhileItsRevealFailsAndLaterDraftsWhileItsApprovalIsLost() async throws {
    let store = try await seeded()
    for chapter in 1...2 {
      try await write(store) { transaction in
        try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction)
        try ChapterWrites.approve(novel: novel, chapter: chapter, in: &transaction)
      }
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 3, in: &transaction) }
    var edit = SecretEdit()
    edit.revealChapter = .set(3)
    let changes = edit
    try await write(store) { transaction in _ = try SecretRecord.edit(SecretRecord.ref(novel: novel, secret: "heir"), changes.fields, in: &transaction) }
    let reason = "a reveal in this plan no longer holds: heir (needs chapter 3 or later)"
    let marked = try await views(store)
    #expect(marked[1] == LifecycleView(review: .needsReview, stale: reason, planStale: reason))
    #expect(marked[2]?.stale == "ancestor chapter 1 lost its approval")
    #expect(marked[3]?.stale == "ancestor chapter 1 lost its approval")
    #expect(marked[3]?.planStale == nil)
    #expect(try await ChapterTables.approvals(novel, in: store).isEmpty)

    var fix = SecretEdit()
    fix.revealChapter = .set(1)
    let fixed = fix
    try await write(store) { transaction in _ = try SecretRecord.edit(SecretRecord.ref(novel: novel, secret: "heir"), fixed.fields, in: &transaction) }
    #expect(try await views(store).values.allSatisfy { $0.stale == nil && $0.planStale == nil })
    #expect(try await ChapterTables.approvals(novel, in: store).count == 2)
  }

  @Test func shouldNeverLetAnAsWrittenApprovalAcceptAFailingReveal() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try PlanWorldWrites.secret(novel: novel, "late", revealChapter: 9, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try PlanWorldWrites.putPlan(novel: novel, chapter: 1, planContent(contract(learns: [Learn("mara", "late")])), in: &transaction) }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 1, kind: .asWritten, in: &transaction) }
    #expect(try await views(store)[1]?.stale == "a reveal in this plan no longer holds: late (needs chapter 9 or later)")
    #expect(try await views(store)[1]?.review == .needsReview)
  }

  @Test func shouldShowAFinalChapterAsFinalAndTheDraftsAfterItRestingOnItsCanon() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    let after = try await views(store)
    #expect(after[1] == LifecycleView(review: .final))
    #expect(after[2]?.stale == nil)
    #expect(try await ChapterTables.knowledge(novel, in: store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
  }

  @Test func shouldKeepADraftFreshWhenTheAncestorWhoseTeachingItRecordedIsFinalizedUnchanged() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction) }
    let recorded = try await store.read { transaction in
      try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 2), in: transaction).entry?.record.content.upstream
    }
    guard case .draft(1, _, let taught?)? = recorded?.entries.first else {
      throw ProjectionPropertyFailure.oracle("chapter 2 recorded no teaching: \(String(describing: recorded))")
    }
    #expect(taught == ChapterFingerprint.learns(teachesHeir))
    try await write(store) { transaction in try ChapterWrites.finalize(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await views(store)[2] == LifecycleView(review: .needsReview))
  }

  @Test func shouldMarkADraftWhoseAncestorWasFinalizedFromAnotherRevision() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
    }
    try await write(store) { transaction in
      let canon = Canon(draftRevision: "v:elsewhere", body: "Final.", contract: teachesHeir)
      _ = try FinalChapterRecord(novel: novel, chapter: 1, canon: canon).finalize(in: &transaction)
    }
    #expect(try await stale(store, 2) == "ancestor chapter 1 was finalized from another revision")
  }

  @Test func shouldRecordTheLatestFinalChapterByItsCanonAndNothingBeforeIt() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      for chapter in 1...2 {
        try ChapterWrites.draft(novel: novel, chapter: chapter, in: &transaction)
        try ChapterWrites.finalize(novel: novel, chapter: chapter, in: &transaction)
      }
    }
    let upstream = try await store.write { transaction in try DraftUpstream.current(novel: novel, chapter: 4, in: transaction) }
    let canon = try await ChapterTables.lifecycle(novel, in: store)[2]?.canonDigest
    #expect(canon != nil)
    #expect(upstream == DraftUpstream(entries: [.canon(chapter: 2, digest: canon), .draft(chapter: 3, revision: nil, taught: nil)]))
    #expect(try await store.write { transaction in try DraftUpstream.current(novel: novel, chapter: 1, in: transaction) } == DraftUpstream(entries: []))
  }

  @Test func shouldTreatADraftThatRecordsAChapterOutOfRangeAsUnrecorded() async throws {
    let store = try await seeded()
    let wrong = DraftUpstream(entries: [.draft(chapter: 2, revision: nil, taught: nil)])
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, recording: .given(wrong), in: &transaction) }
    #expect(try await stale(store, 2) == "the draft does not record what it was written against")
  }

  @Test func shouldShowADraftWhoseUpstreamThisVersionCannotReadAsUnrecordedAndKeepItsProse() async throws {
    let store = try await seeded()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in
      var body = try #require(DraftContent(body: "Newer.", source: .known(.generated)).json.objectValue)
      body["upstream"] = ["chapters": [["chapter": 1, "inserted": true]]]
      let record = try DraftRecord(novel: novel, chapter: 2, content: DraftContent(body: "-", source: .known(.generated)))
      _ = try record.create(in: &transaction)
      _ = try transaction.revise(record.ref, body: .object(body))
    }
    #expect(try await stale(store, 2) == "the draft does not record what it was written against")
    let read = try await store.read { transaction in try DraftRecord.read(try DraftRecord.ref(novel: novel, chapter: 2), in: transaction) }
    #expect(read.entry?.record.content.body == "Newer.")
  }

  @Test(arguments: [UpstreamRecording.none, .given(DraftUpstream(entries: []))])
  func shouldBindAnAcceptedUnrecordedDraftToTheAncestorsAsTheyStood(_ recording: UpstreamRecording) async throws {
    let store = try await seeded()
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction) }
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 2, recording: recording, in: &transaction) }
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, kind: .asWritten, in: &transaction) }
    #expect(try await views(store)[2]?.review == .approved)
    #expect(try await ChapterTables.knowledge(novel, in: store) == [LedgerView("heir", "mara", 2, .brief, .provisional)])
    try await write(store) { transaction in try ChapterWrites.draft(novel: novel, chapter: 1, body: "Again.", in: &transaction) }
    #expect(try await views(store)[2] == LifecycleView(review: .needsReview, stale: "the draft does not record what it was written against"))
    #expect(try await ChapterTables.knowledge(novel, in: store).isEmpty)
    try await write(store) { transaction in try ChapterWrites.approve(novel: novel, chapter: 2, kind: .asWritten, in: &transaction) }
    try await write(store) { transaction in try ChapterWrites.removeDraft(novel: novel, chapter: 1, in: &transaction) }
    #expect(try await views(store)[2]?.review == .needsReview)
  }

  @Test func shouldRecordNothingTaughtByAnAncestorRevisedInTheSameWrite() async throws {
    let store = try await seeded()
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, in: &transaction)
      try ChapterWrites.approve(novel: novel, chapter: 1, in: &transaction)
    }
    try await write(store) { transaction in
      try ChapterWrites.draft(novel: novel, chapter: 1, body: "Again.", in: &transaction)
      try ChapterWrites.draft(novel: novel, chapter: 2, in: &transaction)
    }
    #expect(try await stale(store, 2) == nil)
  }

  @Test func shouldRecordAnUpstreamThatReadsAsUnrecordedWhileTheLifecycleIsFaulted() async throws {
    let store = try Projection.store(try Projection.reconciler(chapterAreaDerivations), allowingFaults: true)
    let upstream = try await store.write { transaction in
      for chapter in 1...2 { try ChapterWrites.draft(novel: novel, chapter: chapter, recording: .none, in: &transaction) }
      try transaction.database.execute(
        sql: "INSERT INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'probe')",
        arguments: [ChapterLifecycleEntry.databaseTableName, ProjectionFaults.wholeDerivation])
      return try DraftUpstream.current(novel: novel, chapter: 3, in: transaction)
    }
    #expect(upstream == DraftUpstream(entries: []))
    #expect(!upstream.fits(chapter: 3))
    let healthy = try await store.write { transaction in
      try transaction.database.execute(sql: "DELETE FROM \(ProjectionFaults.table)")
      return try DraftUpstream.current(novel: novel, chapter: 3, in: transaction)
    }
    #expect(healthy.fits(chapter: 3))
  }

  @Test func shouldReadEveryStoredCauseBack() throws {
    let causes: [StaleCause] = [
      .unrecorded, .canonReplaced(chapter: 2), .ancestorDraft(chapter: 1, change: .drafted), .ancestorDraft(chapter: 1, change: .removed),
      .ancestorDraft(chapter: 1, change: .finalized), .ancestorDraft(chapter: 3, change: .rewritten(source: "x_dictated")),
      .ancestorDraft(chapter: 3, change: .rewritten(source: nil)),
      .ancestorKnowledge(chapter: 4, lost: true), .ancestorKnowledge(chapter: 4, lost: false), .reveal(violations: "heir (needs chapter 3 or later)"),
    ]
    for cause in causes { #expect(StaleCause(code: cause.code, chapter: cause.chapter, detail: cause.detail) == cause) }
    #expect(StaleCause.ancestorDraft(chapter: 3, change: .rewritten(source: "x_dictated")).reason == "ancestor chapter 3 was changed")
  }
}
