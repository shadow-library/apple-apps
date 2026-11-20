import ShadowText

extension ReviewFindings {
  private static let proofreadingMax = 20
  private static let mechanicalPrefix = ProseRegex.literal(#"^mechanical:\s*"#)
  private static let proofreadingChecked = "grammar, spelling, punctuation, tense, point of view, names and references"

  private static func label(_ kind: ProofreadKind) -> String {
    switch kind {
    case .grammar: "Grammar"
    case .spelling: "Spelling"
    case .punctuation: "Punctuation"
    case .tense: "Tense slip"
    case .pov: "Point-of-view slip"
    case .name: "Name"
    case .reference: "Unknown reference"
    }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:247
  static func proofreadingFindings(body: String, slips: [ProofreadSlip]) -> [DraftFinding] {
    var seen = Set<String>()
    var drafts: [DraftFinding] = []
    for slip in slips {
      let quote = slip.quote.jsTrim()
      let fix = slip.fix.jsTrim()
      let key = "\(comparable(quote))|\(comparable(fix))"
      if fix.isEmpty || comparable(quote).jsEquals(comparable(fix)) || seen.contains(key) || verifiedEvidence(body: body, candidates: [quote]) == nil { continue }
      seen.insert(key)
      let reason = slip.reason?.jsTrim() ?? ""
      let because = reason.isEmpty ? "" : " (\(reason))"
      drafts.append(DraftFinding(severity: .warning, category: .proofreading, text: "\(label(slip.kind)): “\(quote)” → “\(fix)”\(because)", evidence: quote))
      if drafts.count == proofreadingMax { break }
    }
    return drafts
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:263
  static func editorialOutcome(body: String, output: ReviewOutput, hasBrief: Bool) -> ReviewOutcome {
    let proofread = output.proofreading != nil
    var drafts = (output.findings ?? []).map { DraftFinding(severity: $0.severity == .blocking ? .blocking : .note, category: .editorial, text: $0.text, evidence: $0.evidence) }
    drafts += proofreadingFindings(body: body, slips: output.proofreading ?? [])
    if !proofread {
      drafts.append(DraftFinding(severity: .note, category: .proofreading, text: "Proofreading was not assessed — the editor left it out. Run the review again to check it."))
    }
    let note = output.note?.jsTrim() ?? ""
    let base = ReviewOutcome(
      verdict: output.disposition.rawValue, note: note.isEmpty ? nil : note,
      checked: (hasBrief ? ["the chapter plan"] : []) + ["canon", "prose against the established style"] + (proofread ? [proofreadingChecked] : []))
    return outcome(kind: .editorial, body: body, base: base, drafts: drafts)
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:292
  static func mechanicsOutcome(body: String, priorBodies: [String], target: ResolvedWordTarget) -> ReviewOutcome {
    let drafts = MechanicalCheck.checkDraftMechanics(body, priorMarkdown: priorBodies, target: target).map {
      DraftFinding(severity: $0.severity == .hard ? .warning : .note, category: .mechanics, text: $0.text.jsReplace(mechanicalPrefix, ""))
    }
    let reused = priorBodies.isEmpty ? [] : ["the opening against the previous chapter", "phrases reused from the previous \(priorBodies.count) chapter(s)"]
    let checked =
      ["prose length, without system panels and tables, against the \(target.min.jsString)–\(target.max.jsString)-word target", "unclosed fences", "repeated paragraphs"] + reused
      + ["stock phrases", "simile frames", "dialogue tags"]
    let base = ReviewOutcome(checked: checked, metrics: ["words": Double(ProseMetrics.countProseWords(body))])
    return outcome(kind: .mechanics, body: body, base: base, drafts: drafts)
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:319
  static func readabilityOutcome(body: String) -> ReviewOutcome {
    let checked = ["sentence length", "paragraph length", "reading grade", "ornate constructions"]
    guard let evidence = ReadabilityCheck.assessReadability(body) else {
      let short = DraftFinding(severity: .note, category: .readability, text: "The chapter is under \(ReadabilityCheck.minWords) words — too short to measure readability.")
      return outcome(kind: .readability, body: body, base: ReviewOutcome(checked: checked), drafts: [short])
    }
    let metrics = evidence.metrics
    var drafts = evidence.overLimits.map { DraftFinding(severity: .note, category: .readability, text: "Over the default’s limit: \($0)") }
    if !evidence.overLimits.isEmpty {
      drafts += evidence.flagged.map { DraftFinding(severity: .note, category: .readability, text: "Flagged sentence (\($0.reason))", evidence: $0.sentence) }
    }
    let base = ReviewOutcome(
      checked: checked, readabilityCompliance: ReviewCompliance(compliant: evidence.overLimits.isEmpty, issues: evidence.overLimits),
      metrics: [
        "words": Double(metrics.words), "averageSentenceWords": metrics.averageSentenceWords, "longSentenceShare": metrics.longSentenceShare,
        "averageParagraphWords": metrics.averageParagraphWords, "readingGrade": metrics.readingGrade, "ornateHitsPer1000Words": metrics.ornateHitsPer1000Words,
      ])
    return outcome(kind: .readability, body: body, base: base, drafts: drafts)
  }
}
