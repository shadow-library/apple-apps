import Foundation
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowJobs

@Suite("Review remedies", .timeLimit(.minutes(3)))
struct ReviewRemedyTests {
  @Test func shouldRefuseAnswersTheReferenceRefuses() async throws {
    let soft = ReviewWorld.judgeReply(verdict: "consistent", findings: [("soft", "A small wrinkle.")])
    let world = try await ReviewWorld(calls: [soft])
    let engine = try world.engine()
    _ = try await world.review(engine, .judge)
    let review = try await world.latest(.judge).review
    let (store, novel) = (world.store, world.novel)
    await #expect(throws: ChapterReviewError.dismissNeedsReason) {
      try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .dismissed, reason: "  ")
    }
    await #expect(throws: ChapterReviewError.overrideNotBlocking) {
      try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .overridden)
    }
    await #expect(throws: ChapterReviewError.findingNotFound("f9")) {
      try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f9", action: .fixingMyself)
    }
    let missing = UUID()
    await #expect(throws: ChapterReviewError.reviewNotFound(missing)) {
      try await store.setReviewRemedy(novel: novel, chapter: 1, review: missing, finding: "f1", action: .fixingMyself)
    }
    try await world.draft(ReviewWorld.body + " The lamp went out.")
    await #expect(throws: ChapterReviewError.reviewStale) {
      try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .fixingMyself)
    }
    #expect(try await world.latest(.judge).stale)
  }

  @Test func shouldSetAndClearARemedyWritingNothingWhenTheAnswerIsUnchanged() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction])
    let engine = try world.engine()
    _ = try await world.review(engine, .judge)
    let review = try await world.latest(.judge).review
    let (store, novel) = (world.store, world.novel)
    let ref = ReviewRemedyRecord.ref(novel: novel, review: review.id, finding: "f1")
    func writes() async throws -> Int {
      try await store.pendingChanges(limit: Int.max).filter { try ChangeRecord(json: try CanonicalJSON.decode($0.line)).ref == ref }.count
    }

    try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .dismissed, reason: " canon allows it ")
    try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .dismissed, reason: "canon allows it")
    #expect(try await writes() == 1)
    #expect(try await world.latest(.judge).remedies["f1"] == ReviewRemedy(action: .known(.dismissed), fingerprint: review.findings[0].fingerprint, reason: "canon allows it"))
    #expect(try await world.lifecycle().openBlocking == 0)

    try await store.clearReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1")
    try await store.clearReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1")
    #expect(try await writes() == 2)
    #expect(try await world.latest(.judge).remedies.isEmpty)
    #expect(try await world.lifecycle().review == .contradiction)

    try await store.setReviewRemedy(novel: novel, chapter: 1, review: review.id, finding: "f1", action: .fixingMyself)
    #expect(try await world.lifecycle().review == .contradiction)
  }

  @Test func shouldAppendAHarmlessSecondReviewCarryingTheAuthorsAnswersWrittenBeforeIt() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine()
    let first = try await world.review(engine, .judge)
    let finding = try await world.latest(.judge).review.findings[0]
    try await world.store.setReviewRemedy(novel: world.novel, chapter: 1, review: first.uuid, finding: "f1", action: .dismissed, reason: "she healed")

    let second = try await world.review(engine, .judge)
    #expect(first != second)
    let list = try await world.reviews()
    #expect(list.history.map(\.review.id) == [second.uuid, first.uuid])
    let latest = try await world.latest(.judge)
    #expect(latest.review.id == second.uuid && latest.review.job != list.history[1].review.job)
    #expect(latest.remedies["f1"] == ReviewRemedy(action: .known(.dismissed), fingerprint: finding.fingerprint, reason: "she healed"))
    #expect(latest.openBlocking == 0)
    #expect(try await world.lifecycle().openBlocking == 0)
    let prompt = try #require(world.provider.requests.last?.messages.last?.text)
    #expect(prompt.contains("## ALREADY SETTLED BY THE AUTHOR") && prompt.contains("- \(finding.text) (the author: she healed)"))

    let order = try await world.store.pendingChanges(limit: Int.max).map { try ChangeRecord(json: try CanonicalJSON.decode($0.line)) }
    let carried = try #require(order.firstIndex { $0.ref == ReviewRemedyRecord.ref(novel: world.novel, review: second.uuid, finding: "f1") })
    let appended = try #require(order.firstIndex { $0.ref == ChapterReviewRecord.ref(second.uuid) })
    #expect(carried < appended && order[carried].clock < order[appended].clock)
  }

  @Test func shouldStopCarryingAnAnswerTheAuthorWithdrew() async throws {
    let world = try await ReviewWorld(calls: [ReviewWorld.contradiction, ReviewWorld.contradiction])
    let engine = try world.engine()
    let first = try await world.review(engine, .judge)
    let (store, novel) = (world.store, world.novel)
    try await store.setReviewRemedy(novel: novel, chapter: 1, review: first.uuid, finding: "f1", action: .overridden)
    try await store.clearReviewRemedy(novel: novel, chapter: 1, review: first.uuid, finding: "f1")
    _ = try await world.review(engine, .judge)
    let latest = try await world.latest(.judge)
    #expect(latest.remedies.isEmpty && latest.openBlocking == 1)
    #expect(world.provider.requests.last?.messages.last?.text.contains("ALREADY SETTLED") == false)
  }

  @Test func shouldKeepTheFirstReviewStoredUnderAnId() async throws {
    let world = try await ReviewWorld()
    let (store, novel) = (world.store, world.novel)
    let id = UUID()
    let stored = try await store.reviewWrite { transaction throws(ChapterReviewError) in
      let source = try ChapterReviews.source(novel: novel, chapter: 1, in: transaction).unwrapped(1)
      let outcome = ReviewFindings.readabilityOutcome(body: source.body)
      let first = try ChapterReviews.append(outcome, kind: .readability, novel: novel, chapter: 1, source: source, isolated: false, id: id, in: &transaction)
      let again = try ChapterReviews.append(outcome, kind: .readability, novel: novel, chapter: 1, source: source, isolated: true, id: id, in: &transaction)
      return [first, again]
    }
    #expect(stored == [true, false])
    #expect(try await world.reviews().history.map(\.review.isolated) == [false])
  }
}

extension Optional {
  fileprivate func unwrapped(_ chapter: Int) throws(ChapterReviewError) -> Wrapped {
    guard let self else { throw .nothingToReview(chapter) }
    return self
  }
}
