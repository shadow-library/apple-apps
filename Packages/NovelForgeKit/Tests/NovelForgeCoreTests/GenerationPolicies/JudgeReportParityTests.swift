import Testing

@testable import NovelForgeCore

struct JudgeReportParityTests {
  private struct Expected: Decodable {
    let verdict: String
    let findings: [FindingFixture]
    let endingCompliance: ComplianceFixture?
    let knowledgeCompliance: ComplianceFixture?
    let briefCompliance: ComplianceFixture?
    let readabilityCompliance: ComplianceFixture?

    var report: JudgeReport {
      JudgeReport(
        verdict: GenerationVerdict(rawValue: verdict) ?? .evaluationFailed, findings: findings.findings, endingCompliance: endingCompliance?.compliance,
        knowledgeCompliance: knowledgeCompliance?.compliance, briefCompliance: briefCompliance?.compliance, readabilityCompliance: readabilityCompliance?.compliance)
    }
  }

  private struct Case: Decodable {
    let raw: String
    let expected: Expected?
  }

  @Test func shouldMatchTheReferenceParseJudgeOutput() throws {
    let cases: [Case] = try GenerationFixtures.load("judge-reports")
    #expect(cases.count > 50)
    var parsed = 0
    for (index, row) in cases.enumerated() {
      switch (try? JudgeReport.parse(row.raw), row.expected) {
      case (let report?, let expected?):
        #expect(report == expected.report, "case \(index)")
        parsed += 1
      case (nil, nil): continue
      default: Issue.record("case \(index) disagrees with the reference on whether the reply parses")
      }
    }
    #expect(parsed > 15 && parsed < cases.count - 15)
  }

  @Test func shouldSeparateAReplyWithoutAnObjectFromOneThatBreaksTheSchema() {
    #expect(throws: JudgeReportError.noJSONObject) { try JudgeReport.parse("no json here at all") }
    #expect(throws: JudgeReportError.noJSONObject) { try JudgeReport.parse("") }
    #expect(throws: JudgeReportError.invalid(issue: "a contradiction needs at least one hard finding")) {
      try JudgeReport.parse(#"{"verdict":"contradiction","findings":[]}"#)
    }
    #expect(throws: JudgeReportError.invalid(issue: "unexpected property extra")) { try JudgeReport.parse(#"{"verdict":"consistent","findings":[],"extra":1}"#) }
  }

  @Test func shouldReportTheFirstIssueWhenNoCandidateMatches() {
    #expect(throws: JudgeReportError.invalid(issue: "unexpected property a")) { try JudgeReport.parse(#"{"a":1} {"verdict":"consistent"}"#) }
  }
}
