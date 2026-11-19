struct DraftJudgeRow: Sendable, Equatable {
  let chapter: Int
  let judge: String?
  let reviewStatus: String
  let status: String
}

struct ApprovalRow: Sendable, Equatable {
  let chapter: Int
}

struct FailOpenViolation: Sendable, Equatable {
  let chapter: Int
  let reviewStatus: String
  let status: String
  let reason: String
}

struct FailOpenInvariantReport: Sendable, Equatable {
  let totalDrafts: Int
  let evaluationFailedCount: Int
  let violations: [FailOpenViolation]
  let holds: Bool
}

struct EvaluationFailedRateReport: Sendable, Equatable {
  let total: Int
  let evaluationFailedCount: Int
  let rate: Double
}

enum ProcessInvariants {
  static let evaluationFailed = "evaluation_failed"

  // apps/novel-forge-server/src/modules/eval/process-invariants.ts:47
  static func checkFailOpen(_ drafts: [DraftJudgeRow], approvals: [ApprovalRow]) -> FailOpenInvariantReport {
    let approved = Set(approvals.map(\.chapter))
    let failed = drafts.filter { $0.judge == evaluationFailed }
    let violations = failed.compactMap { draft -> FailOpenViolation? in
      let reachedClean = draft.reviewStatus == "approved" || draft.reviewStatus == "final" || draft.status == "final"
      guard reachedClean, !approved.contains(draft.chapter) else { return nil }
      return FailOpenViolation(
        chapter: draft.chapter, reviewStatus: draft.reviewStatus, status: draft.status, reason: "reached approved/final status with no human approval row on record")
    }
    return FailOpenInvariantReport(totalDrafts: drafts.count, evaluationFailedCount: failed.count, violations: violations, holds: violations.isEmpty)
  }

  // apps/novel-forge-server/src/modules/eval/process-invariants.ts:73
  static func evaluationFailedRate(_ drafts: [DraftJudgeRow]) -> EvaluationFailedRateReport {
    let failed = drafts.filter { $0.judge == evaluationFailed }.count
    return EvaluationFailedRateReport(total: drafts.count, evaluationFailedCount: failed, rate: drafts.isEmpty ? 0 : Double(failed) / Double(drafts.count))
  }
}

extension FailOpenInvariantReport {
  var json: EvalJSON {
    .object([
      ("totalDrafts", .int(totalDrafts)), ("evaluationFailedCount", .int(evaluationFailedCount)),
      (
        "violations",
        .array(
          violations.map {
            .object([("chapter", .int($0.chapter)), ("reviewStatus", .string($0.reviewStatus)), ("status", .string($0.status)), ("reason", .string($0.reason))])
          })
      ),
      ("holds", .bool(holds)),
    ])
  }
}

extension EvaluationFailedRateReport {
  var json: EvalJSON {
    .object([("total", .int(total)), ("evaluationFailedCount", .int(evaluationFailedCount)), ("rate", .number(rate))])
  }
}
