import Testing

@testable import NovelForgeCore

struct GenerationRoutingParityTests {
  private struct State: Decodable {
    let verdict: String?
    let autoFix: Bool
    let attempt: Int
    let maxFixes: Int
    let findings: [FindingFixture]
    let previousFindings: [FindingFixture]
    let endingCompliant: Bool?
    let knowledgeCompliant: Bool?
    let mechanicallyCompliant: Bool?
    let briefCompliant: Bool?
    let readabilityCompliant: Bool?

    var routing: JudgeRoutingState {
      JudgeRoutingState(
        verdict: verdict.flatMap(GenerationVerdict.init(rawValue:)), autoFix: autoFix, attempt: attempt, maxFixes: maxFixes, findings: findings.findings,
        previousFindings: previousFindings.findings, endingCompliant: endingCompliant ?? true, knowledgeCompliant: knowledgeCompliant ?? true,
        mechanicallyCompliant: mechanicallyCompliant ?? true, briefCompliant: briefCompliant ?? true, readabilityCompliant: readabilityCompliant ?? true)
    }
  }

  private struct JudgeCase: Decodable {
    let state: State
    let route: String
  }

  private struct PatchCase: Decodable {
    let patchApplied: Bool
    let route: String
  }

  private struct Cases: Decodable {
    let afterJudge: [JudgeCase]
    let afterPatch: [PatchCase]
  }

  @Test func shouldMatchTheReferenceRouteAfterJudge() throws {
    let cases: Cases = try GenerationFixtures.load("routes")
    #expect(cases.afterJudge.count > 700)
    var seen = Set<JudgeRoute>()
    for (index, row) in cases.afterJudge.enumerated() {
      let route = GenerationRouting.afterJudge(row.state.routing)
      #expect(route.rawValue == row.route, "case \(index)")
      seen.insert(route)
    }
    #expect(seen == Set(JudgeRoute.allCases))
  }

  @Test func shouldMatchTheReferenceRouteAfterPatch() throws {
    let cases: Cases = try GenerationFixtures.load("routes")
    #expect(cases.afterPatch.count == 2)
    for row in cases.afterPatch { #expect(GenerationRouting.afterPatch(patchApplied: row.patchApplied).rawValue == row.route) }
  }

  @Test func shouldTreatAnAbsentVerdictAsUnsettled() {
    let state = JudgeRoutingState(verdict: nil, autoFix: true, attempt: 0, maxFixes: GenerationRouting.defaultMaxFixes, findings: [], previousFindings: [])
    #expect(GenerationRouting.afterJudge(state) == .repairPatch)
    #expect(GenerationRouting.afterJudge(JudgeRoutingState(verdict: nil, autoFix: false, attempt: 0, maxFixes: 3, findings: [], previousFindings: [])) == .awaitReview)
  }
}
