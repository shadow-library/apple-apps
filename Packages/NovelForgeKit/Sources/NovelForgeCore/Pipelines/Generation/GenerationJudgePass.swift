import Foundation
import ShadowCore

enum GenerationJudgePass {
  static let unparseable = "judge output unparseable"
  static let briefOmitted = "brief: judge omitted briefCompliance — treated as non-compliant"
  static let endingPrefix = "ending contract: "
  static let briefPrefix = "brief: "

  /// The judge node's findings and flags from its parsed report, or from none when the judge could not be read twice.
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:669-697
  static func compose(
    _ report: JudgeReport?, prose: String, hasContract: Bool, forbidden: [DisclosureFact], mechanical: [SourcedFinding]
  ) throws(DisclosureError) -> GenerationJobState.JudgePass {
    var findings = (report?.findings ?? []).map { SourcedFinding($0, source: .continuity) }
    if report == nil { findings.append(SourcedFinding(GenerationFinding(severity: .hard, text: unparseable), source: .continuity)) }
    var silent: [FindingSource] = []

    let ending = hasContract ? report?.endingCompliance : nil
    let endingCompliant = ending?.compliant ?? true
    if let ending, !ending.compliant {
      findings += ending.issues.map { SourcedFinding(GenerationFinding(severity: .soft, text: endingPrefix + $0), source: .ending) }
      if ending.issues.isEmpty { silent.append(.ending) }
    }

    let brief = report?.briefCompliance
    let briefCompliant = brief?.compliant ?? false
    if let brief, !brief.compliant {
      findings += brief.issues.map { SourcedFinding(GenerationFinding(severity: .soft, text: briefPrefix + $0), source: .brief) }
      if brief.issues.isEmpty { silent.append(.brief) }
    } else if brief == nil {
      findings.append(SourcedFinding(GenerationFinding(severity: .soft, text: briefOmitted), source: .brief))
    }

    let readabilityIssues = report?.readabilityCompliance.flatMap { $0.compliant ? nil : $0.issues } ?? []
    findings += readabilityIssues.map { SourcedFinding(GenerationFinding(severity: .soft, text: ReadabilityCheck.prefix + $0), source: .readability) }

    let knowledge = KnowledgeCompliance.merge(
      forbidden.isEmpty ? nil : report?.knowledgeCompliance, prescan: forbidden.isEmpty ? [] : try scanKnowledgeLeaks(prose, hidden: forbidden), forbidden: forbidden)
    findings += knowledge.findings.map { SourcedFinding($0, source: .knowledge) }
    findings += mechanical

    return GenerationJobState.JudgePass(
      verdict: report?.verdict ?? .evaluationFailed, findings: findings, knowledgeWriterFindings: knowledge.writerFindings.map { SourcedFinding($0, source: .knowledge) },
      silent: silent, endingCompliant: endingCompliant, knowledgeCompliant: knowledge.knowledgeCompliant, mechanicallyCompliant: !mechanical.contains { $0.severity == .hard },
      briefCompliant: briefCompliant, readabilityCompliant: readabilityIssues.isEmpty)
  }

  /// graphJudgeOutcome (review-findings.ts:226-244) categorised by source, with a line for a silent block, so it keeps its route (`outcomeHolds`).
  static func outcome(body: String, pass: GenerationJobState.JudgePass) -> ReviewOutcome {
    let drafts = pass.findings.map(draft) + pass.silent.map(silentLine)
    func compliance(_ category: ReviewFindingCategory) -> ReviewCompliance {
      let issues = drafts.filter { $0.category == category }.map(\.text)
      return ReviewCompliance(compliant: issues.isEmpty, issues: issues)
    }
    let failed = pass.verdict == .evaluationFailed
    let base = ReviewOutcome(
      verdict: pass.verdict.rawValue, checked: failed ? [] : ["continuity with the Story Bible", "the chapter plan", "mechanics", "readability"],
      briefCompliance: compliance(.brief), readabilityCompliance: compliance(.readability))
    return ReviewFindings.outcome(kind: .judge, body: body, base: base, drafts: drafts, failed: failed)
  }

  private static func prefix(of source: FindingSource) -> String {
    switch source {
    case .continuity: ""
    case .ending: endingPrefix
    case .brief: briefPrefix
    case .readability: ReadabilityCheck.prefix
    case .knowledge: knowledgeLeakPrefix
    case .mechanics: MechanicalCheck.prefix
    }
  }

  private static func category(of source: FindingSource) -> ReviewFindingCategory {
    switch source {
    case .continuity: .continuity
    case .ending: .ending
    case .brief: .brief
    case .readability: .readability
    case .knowledge: .knowledge
    case .mechanics: .mechanics
    }
  }

  // review-findings.ts:216-223, applied to the finding's source
  private static func draft(_ finding: SourcedFinding) -> DraftFinding {
    let prefix = prefix(of: finding.source)
    let text = !prefix.isEmpty && finding.text.jsStartsWith(prefix) ? finding.text.jsSlice(prefix.jsLength) : finding.text
    let category = category(of: finding.source)
    switch finding.source {
    case .knowledge: return DraftFinding(severity: .blocking, category: category, text: text)
    case .continuity: return DraftFinding(severity: finding.severity == .hard ? .blocking : .warning, category: category, text: text)
    case .mechanics: return DraftFinding(severity: finding.severity == .hard ? .warning : .note, category: category, text: text)
    case .ending, .brief, .readability: return DraftFinding(severity: .warning, category: category, text: text)
    }
  }

  private static func silentLine(_ source: FindingSource) -> DraftFinding {
    let text =
      source == .ending
      ? "The judge found the ending does not keep its contract but named no issue."
      : "The judge found the chapter does not deliver its plan but named no issue."
    return DraftFinding(severity: .warning, category: category(of: source), text: text)
  }
}

extension GenerationJobState.JudgePass {
  func route(in state: GenerationJobState) -> JudgeRoute {
    GenerationRouting.afterJudge(
      JudgeRoutingState(
        verdict: verdict, autoFix: state.pinned.autoFix, attempt: state.attempt, maxFixes: state.pinned.maxFixes, findings: findings.map(\.finding),
        previousFindings: state.previousFindings.map(\.finding), endingCompliant: endingCompliant, knowledgeCompliant: knowledgeCompliant,
        mechanicallyCompliant: mechanicallyCompliant, briefCompliant: briefCompliant, readabilityCompliant: readabilityCompliant))
  }
}
