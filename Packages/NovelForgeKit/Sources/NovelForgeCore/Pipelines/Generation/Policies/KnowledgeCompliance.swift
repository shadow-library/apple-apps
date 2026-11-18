struct KnowledgeComplianceMerge: Equatable, Sendable {
  let knowledgeCompliant: Bool
  let findings: [GenerationFinding]
  let writerFindings: [GenerationFinding]
}

enum KnowledgeCompliance {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:288
  static func merge(_ compliance: JudgeCompliance?, prescan: [KnowledgeLeakIssue], forbidden: [DisclosureFact] = []) -> KnowledgeComplianceMerge {
    let judgeIssues = compliance.flatMap { $0.compliant ? nil : $0.issues } ?? []
    let issues = prescan.map { "\"\($0.term)\" exposes [\($0.factKey)] — \($0.excerpt)" } + judgeIssues
    return KnowledgeComplianceMerge(
      knowledgeCompliant: issues.isEmpty,
      findings: issues.map { GenerationFinding(severity: .soft, text: knowledgeLeakPrefix + $0) },
      writerFindings: writerSafeFindings(prescan: prescan, judgeIssues: judgeIssues, forbidden: forbidden)
    )
  }

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:302
  static func writerSafeFindings(prescan: [KnowledgeLeakIssue], judgeIssues: [String], forbidden: [DisclosureFact]) -> [GenerationFinding] {
    writerSafeLeakLines(prescan: prescan.map { PrescanLeak(factKey: $0.factKey, term: $0.term) }, judgeIssues: judgeIssues, forbidden: forbidden)
      .map { GenerationFinding(severity: .soft, text: $0) }
  }
}
