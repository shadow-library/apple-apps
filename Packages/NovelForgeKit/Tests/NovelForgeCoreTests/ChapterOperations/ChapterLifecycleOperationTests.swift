import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import NovelForgeCore

@Suite("Chapter lifecycle through the operations", .timeLimit(.minutes(2)))
struct ChapterLifecycleOperationTests {
  @Test func shouldCarryAChapterFromPlanToAmendedFinalTextInTheDerivedTables() async throws {
    let book = try await ChapterBook.make()
    let novel = book.novel
    try await book.plan(1, learns: [reveal("mara", "heir")], claims: ["rise"])
    #expect(try await PlanWorldTables.verdicts(novel, in: book.store)[1] == Verdict(.holds))
    #expect(try await PlanWorldTables.milestones(novel, in: book.store)["rise"] == MilestoneSnapshot("planned", planned: 1))
    #expect(try await book.view(1) == LifecycleView(review: nil))

    let head = try await book.draft(1)
    #expect(try await book.view(1) == LifecycleView(review: .needsReview))

    let approval = try await book.approve(1)
    #expect(try await book.view(1) == LifecycleView(review: .approved, approval: approval))
    #expect(try await ChapterTables.approvals(novel, in: book.store) == [1: approval])
    #expect(try await ChapterTables.knowledge(novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .provisional)])

    try await book.finalize(1)
    let lifecycle = try #require(try await book.lifecycle(1))
    #expect(lifecycle.isFinal && lifecycle.review == .final && lifecycle.resting == head)
    #expect(try await ChapterTables.approvals(novel, in: book.store).isEmpty)
    #expect(try await ChapterTables.knowledge(novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .committed)])
    #expect(try await Projection.cursors(in: book.store)[novel] == 2)
    #expect(try await PlanWorldTables.milestones(novel, in: book.store)["rise"] == MilestoneSnapshot("reached", planned: 1, reached: 1))
    #expect(try await PlanWorldTables.verdicts(novel, in: book.store)[1] == Verdict(.settled))
    let canon = try #require(try await book.final(1))
    #expect(try await Projection.finals(in: book.store).first?.approval == approval)

    try await book.run { try FinalChapters.amend(novel: novel, chapter: 1, ChapterAmendment(content: "Amended."), in: &$0) }
    try await book.run { try FinalChapters.editSummary(novel: novel, chapter: 1, summary: "Amended summary.", in: &$0) }
    let final = try #require(try await book.final(1))
    #expect(final.text.body == "Amended.")
    #expect(final.text.summary == "Amended summary.")
    #expect(try await book.lifecycle(1)?.canonDigest == canon.canonDigest)
    #expect(try await ChapterTables.knowledge(novel, in: book.store) == [LedgerView("heir", "mara", 1, .brief, .committed)])

    try await book.draft(2)
    #expect(try await book.draftContent(2)?.upstream == DraftUpstream(entries: [.canon(chapter: 1, digest: canon.canonDigest)]))
    #expect(try await book.view(2) == LifecycleView(review: .needsReview))
    try await Projection.expectNoFaults(in: book.store)
  }

  @Test func shouldTeachLaterDraftsWhatAnApprovedChapterTeachesAndMarkThemWhenTheApprovalIsLost() async throws {
    let book = try await ChapterBook.make()
    try await book.plan(1, learns: [reveal("mara", "heir")])
    try await book.draft(1)
    try await book.approve(1)
    let taught = try #require(try await book.lifecycle(1)?.taught)
    try await book.draft(2)
    #expect(try await book.draftContent(2)?.upstream?.entries.first == .draft(chapter: 1, revision: try await book.head(1), taught: taught))
    try await book.plan(1, learns: [])
    #expect(try await book.view(2)?.stale == "ancestor chapter 1's plan changed what its cast learns after approval")
  }
}
