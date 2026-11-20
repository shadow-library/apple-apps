import ShadowText

enum JudgeRoute: String, CaseIterable, Sendable {
  case accept
  case repairPatch
  case acceptAsIs
  case awaitReview
}

enum PatchRoute: String, CaseIterable, Sendable {
  case persistDraft
  case repairRewrite
}

struct JudgeRoutingState: Equatable, Sendable {
  var verdict: GenerationVerdict?
  var autoFix: Bool
  var attempt: Int
  var maxFixes: Int
  var findings: [GenerationFinding]
  var previousFindings: [GenerationFinding]
  var endingCompliant = true
  var knowledgeCompliant = true
  var mechanicallyCompliant = true
  var briefCompliant = true
  var readabilityCompliant = true
}

enum GenerationRouting {
  static let defaultMaxFixes = 3

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:251
  static func afterJudge(_ state: JudgeRoutingState) -> JudgeRoute {
    if state.verdict == .evaluationFailed { return .awaitReview }
    let otherwiseCompliant = state.verdict == .consistent && state.endingCompliant && state.knowledgeCompliant && state.mechanicallyCompliant && state.briefCompliant
    if otherwiseCompliant && state.readabilityCompliant { return .accept }
    if otherwiseCompliant {
      let readabilityBudgetSpent =
        state.attempt >= state.maxFixes || FindingRepetition.isRepeated(withoutSoftMechanical(state.findings), previous: withoutSoftMechanical(state.previousFindings))
      return state.autoFix && !readabilityBudgetSpent ? .repairPatch : .accept
    }
    let budgetSpent = state.attempt >= state.maxFixes || FindingRepetition.isRepeated(progressSignals(state.findings), previous: progressSignals(state.previousFindings))
    if !state.autoFix { return .awaitReview }
    return budgetSpent ? .acceptAsIs : .repairPatch
  }

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:283
  static func afterPatch(patchApplied: Bool) -> PatchRoute {
    patchApplied ? .persistDraft : .repairRewrite
  }

  private static func withoutSoftMechanical(_ findings: [GenerationFinding]) -> [GenerationFinding] {
    findings.filter { $0.severity != .soft || !$0.text.jsStartsWith(MechanicalCheck.prefix) }
  }

  private static func progressSignals(_ findings: [GenerationFinding]) -> [GenerationFinding] {
    withoutSoftMechanical(findings).filter { !$0.text.jsStartsWith(ReadabilityCheck.prefix) }
  }
}
