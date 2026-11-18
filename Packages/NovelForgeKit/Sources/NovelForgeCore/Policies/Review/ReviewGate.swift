// apps/novel-forge-server/src/modules/review/review-records.ts:28
let approvalOverrideReason = "approved by the author"

struct LatestJudgeReview: Sendable {
  var reviewed: ReviewedText
  var findings: [ReviewFinding]
  var remedies: [ReviewRemedyRecord]
}

struct ApprovalOverride: Equatable, Sendable {
  var findingId: String
  var fingerprint: String
  var action: ReviewRemedyAction
  var reason: String
}

extension ReviewFindings {
  // apps/novel-forge-server/src/modules/review/review-records.ts:151
  static func openBlocking(latest: LatestJudgeReview?, draft: ReviewedText) -> [ReviewFinding] {
    guard let latest, !isStale(latest.reviewed, current: draft) else { return [] }
    return open(latest.findings, remedies: latest.remedies).filter { $0.severity == .known(.blocking) }
  }

  // apps/novel-forge-server/src/modules/review/review-records.ts:163
  static func approvalOverrides(latest: LatestJudgeReview?, draft: ReviewedText) -> [ApprovalOverride] {
    openBlocking(latest: latest, draft: draft).map { ApprovalOverride(findingId: $0.id, fingerprint: $0.fingerprint, action: .overridden, reason: approvalOverrideReason) }
  }
}
