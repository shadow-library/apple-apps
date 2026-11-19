import Foundation
import Testing

@testable import NovelForgeCore
@testable import NovelForgeEval

private struct MetricsCase: Decodable {
  struct Chapter: Decodable {
    let chapter: Int
    let body: String
    let hookType: String?
  }

  struct Target: Decodable {
    let min: Int
    let max: Int
  }

  let name: String
  let chapters: [Chapter]
  let priorWindow: Int
  let target: Target?
  let expected: String
}

private struct InvariantCase: Decodable {
  struct Draft: Decodable {
    let chapter: Int
    let judge: String?
    let reviewStatus: String
    let status: String
  }

  let name: String
  let drafts: [Draft]
  let approvals: [Int]
  let failOpen: String
  let rate: String
}

@Suite("Eval parity", TestTimeLimit.standard)
struct EvalParityTests {
  @Test func shouldMatchTheReferenceMetricsReportForEveryCase() throws {
    let cases = try ReferenceFixture.decode([MetricsCase].self, from: "eval/metrics.json")
    #expect(cases.count == 5)
    for entry in cases {
      let chapters = entry.chapters.map {
        EvaluationChapter(chapter: $0.chapter, body: $0.body, hookType: $0.hookType, judge: nil, reviewStatus: "needs_review", status: "draft", approved: false)
      }
      let target = entry.target.map { WordTarget(min: $0.min, max: $0.max) }
      #expect(NovelEvaluation.proseMetrics(chapters, priorWindow: entry.priorWindow, wordTarget: target) == entry.expected, "\(entry.name)")
    }
  }

  @Test func shouldMatchTheReferenceInvariantReportsForEveryCase() throws {
    let cases = try ReferenceFixture.decode([InvariantCase].self, from: "eval/invariants.json")
    #expect(cases.count == 5)
    for entry in cases {
      let drafts = entry.drafts.map { DraftJudgeRow(chapter: $0.chapter, judge: $0.judge, reviewStatus: $0.reviewStatus, status: $0.status) }
      let approvals = entry.approvals.map(ApprovalRow.init(chapter:))
      #expect(ProcessInvariants.checkFailOpen(drafts, approvals: approvals).json.compact == entry.failOpen, "\(entry.name)")
      #expect(ProcessInvariants.evaluationFailedRate(drafts).json.compact == entry.rate, "\(entry.name)")
    }
  }

  @Test func shouldIndentCompactJSONWithoutChangingItsTokens() {
    let compact = #"{"a":[1,2,{"b":"x,y:{z}\"q"}],"c":{},"d":[]}"#
    let pretty = JSONReindent.pretty(compact)
    #expect(pretty.contains(#""b": "x,y:{z}\"q""#) && pretty.contains(#""c": {}"#) && pretty.contains(#""d": []"#))
    #expect(pretty.filter { !$0.isWhitespace } == compact)
  }
}
