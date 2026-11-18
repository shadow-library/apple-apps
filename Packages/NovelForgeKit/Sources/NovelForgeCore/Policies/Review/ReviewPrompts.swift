// apps/novel-forge-server/src/modules/review/review-prompts.ts:5
struct SettledFinding: Equatable, Sendable {
  var fingerprint: String
  var action: StoredEnum<ReviewRemedyAction>
  var reason: String?
  var text: String
}

// apps/novel-forge-server/src/modules/review/review-prompts.ts:12
struct JudgeTask: Sendable {
  var body: String
  var chapterBrief: String?
  var endingContract: String
  var lockedFromReader: [DisclosureFact]
  var hiddenFromCast: [DisclosureFact]
  var readabilityEvidence: String?
  var settled: [SettledFinding]
}

enum ReviewPrompts {
  // apps/novel-forge-server/src/modules/review/review-prompts.ts:23
  private static func renderForbiddenWithClues(_ facts: [DisclosureFact]) -> String {
    facts.map { fact in
      let clues = (fact.allowedClues ?? []).map { $0.jsTrim() }.filter { !$0.isEmpty }
      let allowed = clues.isEmpty ? "" : "\n  Allowed clues (may be shown without the explanation): \(clues.joined(separator: "; "))"
      return "- [\(fact.factKey)] \(fact.text)\(allowed)"
    }.joined(separator: "\n")
  }

  // apps/novel-forge-server/src/modules/review/review-prompts.ts:32
  static func renderSettledFindings(_ settled: [SettledFinding]) -> String {
    let lines = settled.filter { $0.action != .known(.fixingMyself) && !$0.text.isEmpty }.map { finding in
      let author = finding.reason.flatMap { $0.isEmpty ? nil : " (the author: \($0))" } ?? ""
      return "- \(finding.text)\(author)"
    }
    if lines.isEmpty { return "" }
    return "\n\n## ALREADY SETTLED BY THE AUTHOR\nThe author dismissed or overrode these findings on this exact text. Do not raise them again:\n\(lines.joined(separator: "\n"))"
  }

  // apps/novel-forge-server/src/modules/review/review-prompts.ts:41
  static func renderJudgeTask(_ task: JudgeTask) -> String {
    let brief =
      task.chapterBrief.flatMap { $0.isEmpty ? nil : $0 }.map {
        "\n\n## BRIEF\n\($0)\n\nThis is the plan the chapter was written from — assess whether the draft delivers it and include briefCompliance in your JSON."
      } ?? ""
    let contract =
      task.endingContract.isEmpty
      ? "" : "\n\n## ENDING CONTRACT\n\(task.endingContract)\n\nAlso assess the draft ending against this contract and include endingCompliance in your JSON."
    let locked =
      task.lockedFromReader.isEmpty
      ? ""
      : "### Locked from the reader\nThe reader must not learn these yet. Flag any passage that states, paraphrases or lets the reader infer one; an allowed clue is not a leak.\n\(renderForbiddenWithClues(task.lockedFromReader))"
    let hidden =
      task.hiddenFromCast.isEmpty
      ? ""
      : "### Hidden from the point-of-view cast\nThe reader may already know these, so the page may mention them. Flag only a point-of-view character who knows, says or acts on one.\n\(renderForbiddenWithClues(task.hiddenFromCast))"
    let forbidden = [locked, hidden].filter { !$0.isEmpty }
    let knowledge =
      forbidden.isEmpty ? "" : "\n\n## FORBIDDEN KNOWLEDGE\n\(forbidden.joined(separator: "\n\n"))\n\nInclude knowledgeCompliance in your JSON, each issue citing the fact key."
    let readability =
      task.readabilityEvidence.flatMap { $0.isEmpty ? nil : $0 }.map {
        "\n\n\($0)\n\nWeigh this evidence in readabilityCompliance; the project's writing-style additions win where they allow this prose."
      } ?? ""
    return [
      "Draft prose to evaluate:\n\(task.body)\(brief)\(contract)\(knowledge)\(readability)\(renderSettledFindings(task.settled))",
      "Evaluate this chapter draft for continuity and consistency with the established canon. You review only — never rewrite the chapter. Return a JSON object with verdict (\"consistent\" or \"contradiction\") and findings array.",
    ].joined(separator: "\n\n")
  }
}
