// apps/novel-forge-server/src/modules/review/review-findings.ts:75
func hashReviewedBody(_ body: String) -> String {
  sha256Hex(body)
}

enum ReviewFindings {
  private static let quoted = ProseRegex.literal(#"["“]([^"“”]{12,}?)["”]"#, "g")
  private static let ellipsis = ProseRegex.literal(#"^(?:…|\.{3})|(?:…|\.{3})$"#, "g")
  private static let curlyDoubleQuote = ProseRegex.literal(#"[“”]"#, "g")
  private static let curlySingleQuote = ProseRegex.literal(#"[‘’]"#, "g")
  private static let nonAlphanumericRun = ProseRegex.literal(#"[^\p{L}\p{N}]+"#, "gu")
  private static let fingerprintLength = 24
  private static let evidenceMinLength = 3

  // apps/novel-forge-server/src/modules/review/review-findings.ts:71
  static func comparable(_ text: String) -> String {
    text.jsReplace(curlyDoubleQuote, "\"").jsReplace(curlySingleQuote, "'").jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim().jsToLowerCase()
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:80
  static func isStale(_ review: ReviewedText, current: ReviewedText?) -> Bool {
    guard let current else { return true }
    return !sameRevision(review.draftRevision, current.draftRevision) || review.bodyHash != current.bodyHash
  }

  private static func sameRevision(_ left: String?, _ right: String?) -> Bool {
    switch (left, right) {
    case (nil, nil): true
    case (let left?, let right?): left.jsEquals(right)
    default: false
    }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:85
  static func fingerprint(kind: ChapterReviewKind, category: ReviewFindingCategory, text: String) -> String {
    let normalized = text.jsToLowerCase().jsReplace(nonAlphanumericRun, " ").jsTrim()
    return sha256Hex("\(kind.rawValue)|\(category.rawValue)|\(normalized)").jsSlice(0, fingerprintLength)
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:94
  static func verifiedEvidence(body: String, candidates: [String?]) -> String? {
    let haystack = comparable(body)
    for candidate in candidates {
      guard let candidate else { continue }
      let quote = candidate.jsTrim().jsReplace(ellipsis, "").jsTrim()
      if quote.jsLength >= evidenceMinLength, haystack.jsIncludes(comparable(quote)) { return quote }
    }
    return nil
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:103
  private static func quotes(in text: String) -> [String] {
    text.jsMatchAll(quoted).compactMap { $0.groups.first.flatMap { $0 } }.filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:107
  static func settle(kind: ChapterReviewKind, body: String, drafts: [DraftFinding]) -> [ReviewFinding] {
    drafts.enumerated().map { index, draft in
      ReviewFinding(
        id: "f\(index + 1)", severity: .known(draft.severity), category: .known(draft.category), text: draft.text,
        evidence: verifiedEvidence(body: body, candidates: [draft.evidence] + quotes(in: draft.text)),
        fingerprint: fingerprint(kind: kind, category: draft.category, text: draft.text))
    }
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:118
  static func disposition(of findings: [ReviewFinding], failed: Bool = false) -> ChapterReviewDisposition {
    if failed { return .failed }
    if findings.contains(where: { $0.severity == .known(.blocking) }) { return .blocking }
    return findings.isEmpty ? .clear : .issues
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:124
  static func outcome(kind: ChapterReviewKind, body: String, base: ReviewOutcome, drafts: [DraftFinding], failed: Bool = false) -> ReviewOutcome {
    var result = base
    result.findings = settle(kind: kind, body: body, drafts: drafts)
    result.disposition = disposition(of: result.findings, failed: failed)
    return result
  }

  // apps/novel-forge-server/src/modules/review/review-findings.ts:368
  static func open(_ findings: [ReviewFinding], remedies: [ReviewRemedyRecord]) -> [ReviewFinding] {
    let settled = Set(remedies.filter { $0.remedy.map { $0.action != .known(.fixingMyself) } ?? false }.map(\.finding))
    return findings.filter { !settled.contains($0.id) }
  }
}
