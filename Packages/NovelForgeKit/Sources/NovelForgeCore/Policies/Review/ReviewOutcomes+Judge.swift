extension ReviewFindings {
  private static let graphCategories: [(prefix: String, category: ReviewFindingCategory)] = [
    ("ending contract: ", .ending), ("brief: ", .brief), (knowledgeLeakPrefix, .knowledge), (ReadabilityCheck.prefix, .readability), (MechanicalCheck.prefix, .mechanics),
  ]

  private static func plural(_ count: Int, _ word: String) -> String {
    "\(count) \(word)\(count == 1 ? "" : "s")"
  }

  private static func notAssessed(_ what: String) -> DraftFinding {
    DraftFinding(severity: .note, category: .continuity, text: "\(what) was not assessed — the judge left it out. Run the review again to check it.")
  }

  private static func issues(of compliance: ReviewCompliance?, as category: ReviewFindingCategory) -> [DraftFinding] {
    guard let compliance, !compliance.compliant else { return [] }
    return compliance.issues.map { DraftFinding(severity: .warning, category: category, text: $0) }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:146
  static func judgeOutcome(body: String, evidence: JudgeEvidence) -> ReviewOutcome {
    let output = evidence.output
    let locked = evidence.lockedFromReader.count
    let hidden = evidence.hiddenFromCast.count
    let secrets = locked + hidden
    let briefCompliance = evidence.hasBrief ? output?.briefCompliance : nil
    let endingCompliance = evidence.hasEndingContract ? output?.endingCompliance : nil
    let readabilityCompliance = output?.readabilityCompliance
    let judgedKnowledge = secrets > 0 ? output?.knowledgeCompliance : nil
    let judgedLeaks = judgedKnowledge.flatMap { $0.compliant ? nil : $0.issues } ?? []
    let scannedLeaks = evidence.leaks.map { "\"\($0.term)\" gives away [\($0.factKey)]" }
    let knowledgeCompliance = secrets > 0 ? ReviewCompliance(compliant: scannedLeaks.isEmpty && judgedLeaks.isEmpty, issues: scannedLeaks + judgedLeaks) : nil

    let briefAssessed = evidence.hasBrief && briefCompliance != nil
    let endingAssessed = evidence.hasEndingContract && endingCompliance != nil
    let knowledgeAssessed = secrets > 0 && judgedKnowledge != nil
    let readabilityAssessed = readabilityCompliance != nil

    var omitted: [DraftFinding] = []
    if output != nil {
      if evidence.hasBrief && !briefAssessed { omitted.append(notAssessed("Plan compliance")) }
      if evidence.hasEndingContract && !endingAssessed { omitted.append(notAssessed("The ending contract")) }
      if secrets > 0 && !knowledgeAssessed { omitted.append(notAssessed("Secret-keeping beyond give-away words")) }
      if !readabilityAssessed { omitted.append(notAssessed("Readability")) }
    }

    var drafts = (output?.findings ?? []).map { DraftFinding(severity: $0.severity == .hard ? .blocking : .warning, category: .continuity, text: $0.text) }
    if output == nil {
      drafts.append(DraftFinding(severity: .blocking, category: .continuity, text: "The judge’s answer could not be read, so nothing was checked — run the review again."))
    }
    drafts += issues(of: endingCompliance, as: .ending)
    drafts += issues(of: briefCompliance, as: .brief)
    drafts += evidence.leaks.map {
      DraftFinding(severity: .blocking, category: .knowledge, text: "\"\($0.term)\" gives away [\($0.factKey)] before it is revealed", evidence: $0.excerpt)
    }
    drafts += judgedLeaks.map { DraftFinding(severity: .blocking, category: .knowledge, text: $0) }
    drafts += issues(of: readabilityCompliance, as: .readability)
    drafts += omitted

    var checked: [String] = []
    if output != nil {
      checked.append("continuity with the Story Bible")
      if briefAssessed { checked.append("the chapter plan") }
      if endingAssessed { checked.append("the ending contract") }
      if locked > 0 { checked.append("\(plural(locked, "secret")) kept from the reader") }
      if hidden > 0 { checked.append("\(plural(hidden, "fact")) the point-of-view cast does not know") }
      if readabilityAssessed { checked.append("readability") }
    }
    let base = ReviewOutcome(
      verdict: output?.verdict ?? "evaluation_failed", checked: checked, briefCompliance: briefCompliance, readabilityCompliance: readabilityCompliance,
      endingCompliance: endingCompliance, knowledgeCompliance: knowledgeCompliance)
    return outcome(kind: .judge, body: body, base: base, drafts: drafts, failed: output == nil)
  }

  private static func graphFinding(_ finding: CheckFinding) -> DraftFinding {
    let match = graphCategories.first { finding.text.jsStartsWith($0.prefix) }
    let category = match?.category ?? .continuity
    let text = finding.text.jsSlice(match?.prefix.jsLength ?? 0)
    switch category {
    case .knowledge: return DraftFinding(severity: .blocking, category: category, text: text)
    case .continuity: return DraftFinding(severity: finding.severity == .hard ? .blocking : .warning, category: category, text: text)
    case .mechanics: return DraftFinding(severity: finding.severity == .hard ? .warning : .note, category: category, text: text)
    default: return DraftFinding(severity: .warning, category: category, text: text)
    }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:226
  static func graphJudgeOutcome(body: String, verdict: String?, findings: [CheckFinding]) -> ReviewOutcome {
    let drafts = findings.map(graphFinding)
    func compliance(_ category: ReviewFindingCategory) -> ReviewCompliance {
      let issues = drafts.filter { $0.category == category }.map(\.text)
      return ReviewCompliance(compliant: issues.isEmpty, issues: issues)
    }
    let failed = verdict?.jsEquals("evaluation_failed") ?? false
    let base = ReviewOutcome(
      verdict: verdict ?? "evaluation_failed", checked: failed ? [] : ["continuity with the Story Bible", "the chapter plan", "mechanics", "readability"],
      briefCompliance: compliance(.brief), readabilityCompliance: compliance(.readability))
    return outcome(kind: .judge, body: body, base: base, drafts: drafts, failed: failed)
  }
}
