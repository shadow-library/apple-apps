import Foundation
import NovelForgeCore

struct EvalStep: Sendable, Equatable {
  enum Name: String, Sendable {
    case plan
    case generate
    case review
    case finalizeReview = "finalize_review"
    case finalize
    case refresh
  }

  enum Outcome: Sendable, Equatable {
    case succeeded
    case failed(String)
    case refused(String)

    var text: String {
      switch self {
      case .succeeded: "succeeded"
      case .failed(let code): "failed:\(code)"
      case .refused(let code): "refused:\(code)"
      }
    }

    var isFailure: Bool {
      switch self {
      case .failed, .refused: true
      case .succeeded: false
      }
    }
  }

  let chapter: Int
  let name: Name
  let outcome: Outcome
}

struct EvalReport: Sendable {
  let novel: UUID
  let steps: [EvalStep]
  let chapters: [EvaluationChapter]
  let skipped: [EvaluationSkip]
  let toolApproved: [Int]
  let metrics: String
  let failOpen: FailOpenInvariantReport
  let evaluationFailedRate: EvaluationFailedRateReport

  init(novel: UUID, steps: [EvalStep], chapters: [EvaluationChapter], skipped: [EvaluationSkip] = [], priorWindow: Int, wordTarget: WordTarget?) {
    let toolApproved = Set(steps.filter { $0.name == .finalizeReview }.map(\.chapter))
    let drafts = chapters.map { DraftJudgeRow(chapter: $0.chapter, judge: $0.judge, reviewStatus: $0.reviewStatus, status: $0.status) }
    self.novel = novel
    self.steps = steps
    self.chapters = chapters
    self.skipped = skipped
    self.toolApproved = toolApproved.sorted()
    metrics = NovelEvaluation.proseMetrics(chapters, priorWindow: priorWindow, wordTarget: wordTarget)
    failOpen = ProcessInvariants.checkFailOpen(
      drafts.filter { !toolApproved.contains($0.chapter) }, approvals: chapters.filter(\.approved).map { ApprovalRow(chapter: $0.chapter) })
    evaluationFailedRate = ProcessInvariants.evaluationFailedRate(drafts)
  }

  var passed: Bool { failOpen.holds && !steps.contains { $0.outcome.isFailure } }

  var json: EvalJSON {
    .object([
      ("novel", .string(novel.uuidString.lowercased())),
      ("passed", .bool(passed)),
      ("steps", .array(steps.map { .object([("chapter", .int($0.chapter)), ("step", .string($0.name.rawValue)), ("outcome", .string($0.outcome.text))]) })),
      (
        "chapters",
        .array(
          chapters.map {
            .object([
              ("chapter", .int($0.chapter)), ("status", .string($0.status)), ("reviewStatus", .string($0.reviewStatus)), ("judge", .optional($0.judge)),
              ("approved", .bool($0.approved)),
            ])
          })
      ),
      ("skipped", .array(skipped.map { .object([("chapter", .int($0.chapter)), ("reason", .string($0.reason))]) })),
      ("metrics", .raw(metrics)),
      ("invariants", .object([("failOpen", failOpen.json), ("failOpenExcluded", .array(toolApproved.map { .int($0) })), ("evaluationFailedRate", evaluationFailedRate.json)])),
    ])
  }
}
