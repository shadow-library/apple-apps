import Foundation
import ShadowCore
import Testing

@testable import NovelForgeCore

struct ReviewFindingsTests {
  private let novel = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
  private let review = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

  private func finding(_ id: String, _ severity: ReviewFindingSeverity = .blocking) -> ReviewFinding {
    ReviewFinding(id: id, severity: .known(severity), category: .known(.continuity), text: "text \(id)", fingerprint: "fp-\(id)")
  }

  private func record(_ id: String, _ action: String?) -> ReviewRemedyRecord {
    ReviewRemedyRecord(novel: novel, review: review, finding: id, remedy: action.map { ReviewRemedy(action: StoredEnum(rawValue: $0), fingerprint: "fp-\(id)") })
  }

  @Test func shouldReopenAFindingWhoseRemedyWasCleared() {
    let open = ReviewFindings.open([finding("f1"), finding("f2")], remedies: [record("f1", nil), record("f2", "dismissed")])
    #expect(open.map(\.id) == ["f1"])
  }

  @Test func shouldKeepFixingMyselfOpenAndCloseOverriddenAndUnknownActions() {
    let findings = [finding("f1"), finding("f2"), finding("f3"), finding("f4")]
    let remedies = [record("f1", "fixing_myself"), record("f2", "overridden"), record("f3", "from_the_future")]
    #expect(ReviewFindings.open(findings, remedies: remedies).map(\.id) == ["f1", "f4"])
  }

  @Test func shouldOverrideOnlyOpenBlockingFindingsOnApproval() {
    let body = "Mara climbs."
    let latest = LatestJudgeReview(
      reviewed: ReviewedText(draftRevision: "3", body: body), findings: [finding("f1"), finding("f2", .warning), finding("f3"), finding("f4")],
      remedies: [record("f3", "dismissed"), record("f4", "fixing_myself")])
    let overrides = ReviewFindings.approvalOverrides(latest: latest, draft: ReviewedText(draftRevision: "3", body: body))
    #expect(overrides.map(\.findingId) == ["f1", "f4"])
    #expect(overrides.allSatisfy { $0.action == .overridden && $0.reason == "approved by the author" })
  }

  @Test func shouldNotOverrideAnythingOnAStaleReview() {
    let latest = LatestJudgeReview(reviewed: ReviewedText(draftRevision: "3", body: "Mara climbs."), findings: [finding("f1")], remedies: [])
    #expect(ReviewFindings.approvalOverrides(latest: latest, draft: ReviewedText(draftRevision: "4", body: "Mara climbs.")).isEmpty)
    #expect(ReviewFindings.approvalOverrides(latest: latest, draft: ReviewedText(draftRevision: "3", body: "Mara climbs!")).isEmpty)
    #expect(ReviewFindings.approvalOverrides(latest: nil, draft: ReviewedText(draftRevision: "3", body: "Mara climbs.")).isEmpty)
  }

  @Test func shouldNumberDuplicateDraftsSeparately() {
    let draft = DraftFinding(severity: .warning, category: .continuity, text: "Ten lanterns")
    let settled = ReviewFindings.settle(kind: .judge, body: "Ten lanterns.", drafts: [draft, draft])
    #expect(settled.map(\.id) == ["f1", "f2"])
    #expect(settled[0].fingerprint == settled[1].fingerprint)
  }
}
