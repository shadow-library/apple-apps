import Foundation
import NovelForgeCore
import Testing

@testable import NovelForgeEval

@Suite("Eval process invariants", TestTimeLimit.standard)
struct EvalInvariantTests {
  private static let approved = DraftJudgeRow(chapter: 1, judge: "consistent", reviewStatus: "approved", status: "draft")
  private static let failedOpen = DraftJudgeRow(chapter: 2, judge: ProcessInvariants.evaluationFailed, reviewStatus: "contradiction", status: "draft")

  @Test func shouldHoldWhenNoFailedJudgeReachedApprovedOrFinal() {
    let report = ProcessInvariants.checkFailOpen([Self.approved, Self.failedOpen], approvals: [ApprovalRow(chapter: 1)])
    #expect(report.holds && report.violations.isEmpty && report.evaluationFailedCount == 1 && report.totalDrafts == 2)
  }

  @Test func shouldHoldWhenAFailedJudgeReachedApprovedWithAHumanApproval() {
    let draft = DraftJudgeRow(chapter: 3, judge: ProcessInvariants.evaluationFailed, reviewStatus: "approved", status: "draft")
    #expect(ProcessInvariants.checkFailOpen([draft], approvals: [ApprovalRow(chapter: 3)]).holds)
  }

  @Test func shouldFailWhenAFailedJudgeReachedApprovedWithNoApproval() {
    let draft = DraftJudgeRow(chapter: 3, judge: ProcessInvariants.evaluationFailed, reviewStatus: "approved", status: "draft")
    let report = ProcessInvariants.checkFailOpen([Self.approved, draft], approvals: [ApprovalRow(chapter: 1)])
    #expect(!report.holds)
    #expect(
      report.violations == [FailOpenViolation(chapter: 3, reviewStatus: "approved", status: "draft", reason: "reached approved/final status with no human approval row on record")])
  }

  @Test func shouldFailWhenAFailedJudgeReachedFinalWithNoApproval() {
    let draft = DraftJudgeRow(chapter: 4, judge: ProcessInvariants.evaluationFailed, reviewStatus: "contradiction", status: "final")
    #expect(ProcessInvariants.checkFailOpen([draft], approvals: []).violations.map(\.chapter) == [4])
  }

  @Test func shouldCountTheFailedJudgeRateAndGuardAnEmptyRun() {
    let rate = ProcessInvariants.evaluationFailedRate([Self.approved, Self.failedOpen, Self.failedOpen, Self.approved])
    #expect(rate == EvaluationFailedRateReport(total: 4, evaluationFailedCount: 2, rate: 0.5))
    #expect(ProcessInvariants.evaluationFailedRate([]) == EvaluationFailedRateReport(total: 0, evaluationFailedCount: 0, rate: 0))
  }

  @Test func shouldFailTheReportWhenAChapterFailedOpen() {
    let seeded = EvaluationChapter(
      chapter: 1, body: "Mara waits.", hookType: nil, judge: ProcessInvariants.evaluationFailed, reviewStatus: "approved", status: "draft", approved: false)
    let violated = EvalReport(novel: EvalFixture.novel, steps: [], chapters: [seeded], priorWindow: 10, wordTarget: nil)
    #expect(!violated.passed && !violated.failOpen.holds)
    let honest = EvaluationChapter(
      chapter: 1, body: "Mara waits.", hookType: nil, judge: ProcessInvariants.evaluationFailed, reviewStatus: "approved", status: "draft", approved: true)
    #expect(EvalReport(novel: EvalFixture.novel, steps: [], chapters: [honest], priorWindow: 10, wordTarget: nil).passed)
  }

  @Test func shouldFailTheReportWhenAStepFailed() {
    let steps = [EvalStep(chapter: 1, name: .generate, outcome: .failed("AI_001"))]
    #expect(!EvalReport(novel: EvalFixture.novel, steps: steps, chapters: [], priorWindow: 10, wordTarget: nil).passed)
    #expect(EvalReport(novel: EvalFixture.novel, steps: [EvalStep(chapter: 1, name: .refresh, outcome: .succeeded)], chapters: [], priorWindow: 10, wordTarget: nil).passed)
  }

  @Test func shouldLeaveOutChaptersTheToolApprovedItselfFromTheFailOpenInvariant() {
    let chapter = EvaluationChapter(
      chapter: 1, body: "Mara waits.", hookType: nil, judge: ProcessInvariants.evaluationFailed, reviewStatus: "final", status: "final", approved: false)
    let steps = [EvalStep(chapter: 1, name: .finalizeReview, outcome: .succeeded)]
    let report = EvalReport(novel: EvalFixture.novel, steps: steps, chapters: [chapter], priorWindow: 10, wordTarget: nil)
    #expect(report.failOpen.totalDrafts == 0 && report.failOpen.holds && report.toolApproved == [1])
    #expect(report.json.compact.contains(#""failOpenExcluded":[1]"#))
    #expect(!EvalReport(novel: EvalFixture.novel, steps: [], chapters: [chapter], priorWindow: 10, wordTarget: nil).failOpen.holds)
  }
}
