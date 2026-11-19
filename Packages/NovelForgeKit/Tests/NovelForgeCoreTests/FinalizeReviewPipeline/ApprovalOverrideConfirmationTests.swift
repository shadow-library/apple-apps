import Foundation
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore

/// The author confirms how many open blocking findings an approval overrides; a judge review that lands between that confirmation and the write would
/// otherwise be overridden without their knowing.
@Suite("Approval override confirmation", TestTimeLimit.standard)
struct ApprovalOverrideConfirmationTests {
  @Test func shouldRefuseAnApprovalThatWouldOverrideMoreFindingsThanTheAuthorConfirmed() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let review = try await judge(world, revision: head)
    await #expect(throws: DomainError.approvalOverridesUnconfirmed(chapter: 1, open: 2)) {
      try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head, confirmedOverrides: 1)
    }
    #expect(try await overridden(world, review: review).isEmpty)
    #expect(try await world.store.finalizeReviewJob(novel: world.novel, chapter: 1) == nil)
  }

  @Test func shouldApproveOnceTheNewCountIsConfirmedAndSayHowManyWereOverridden() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    let review = try await judge(world, revision: head)
    await #expect(throws: DomainError.approvalOverridesUnconfirmed(chapter: 1, open: 2)) {
      try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head, confirmedOverrides: 0)
    }
    let approval = try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head, confirmedOverrides: 2)
    #expect(approval.overridden == 2)
    #expect(try await overridden(world, review: review) == ["blocking-a", "blocking-b"])
    #expect(try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head, confirmedOverrides: 0) == ChapterApproval(id: approval.id, overridden: 0))
  }

  @Test func shouldOverrideNothingWithoutAJudgeReview() async throws {
    let world = try await FinalizeReviewWorld()
    let head = try await world.draft()
    #expect(try await world.store.approveChapter(novel: world.novel, chapter: 1, revision: head, confirmedOverrides: 0).overridden == 0)
  }

  private func judge(_ world: FinalizeReviewWorld, revision: String) async throws -> UUID {
    let findings = [
      ReviewFinding(id: "blocking-a", severity: .known(.blocking), category: .known(.continuity), text: "A.", fingerprint: "f-a"),
      ReviewFinding(id: "blocking-b", severity: .known(.blocking), category: .known(.continuity), text: "B.", fingerprint: "f-b"),
      ReviewFinding(id: "warning", severity: .known(.warning), category: .known(.continuity), text: "W.", fingerprint: "f-w"),
    ]
    let review = try ChapterReviewRecord(
      novel: world.novel, chapter: 1, reviewKind: .known(.judge), draftRevision: revision, bodyHash: hashReviewedBody(FinalizeReviewScript.prose),
      disposition: .known(.blocking), findings: findings)
    try await Projection.write(world.store) { transaction in _ = try review.append(in: &transaction) }
    return review.id
  }

  private func overridden(_ world: FinalizeReviewWorld, review: UUID) async throws -> [String] {
    let novel = world.novel
    return try await world.store.read { transaction in
      try ["blocking-a", "blocking-b", "warning"].filter { finding in
        guard case .readable(let entry) = try ReviewRemedyRecord.read(novel: novel, review: review, finding: finding, in: transaction) else { return false }
        return entry.record.remedy?.action == .known(.overridden)
      }
    }
  }
}
