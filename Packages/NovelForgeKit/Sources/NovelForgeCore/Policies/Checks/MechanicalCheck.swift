import ShadowText

struct WordCountBounds: Equatable, Sendable {
  let min: Double
  let max: Double
}

enum MechanicalCheck {
  static let prefix = "mechanical: "
  static let wordCountHardSlack = 600.0
  static let duplicateParagraphMinWords = 20
  static let boundaryEchoWindowWords = 60
  static let boundaryEchoNgramSize = 6

  private static let crossChapterNgramRateMax = 0.05
  private static let stockPhraseMax = 5
  private static let dialogueTagsPer1000Max = 25.0
  private static let dialogueTagRateMinSample = 10
  private static let saidAlternativeRateMax = 0.5

  static let paragraphBreak = ProseRegex.literal(#"\n\s*\n"#)

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:19
  static func resolveWordCountHardBounds(_ target: ResolvedWordTarget) -> WordCountBounds {
    WordCountBounds(min: target.min - wordCountHardSlack, max: target.max + wordCountHardSlack)
  }

  static let wordCountHardMin = resolveWordCountHardBounds(.resolve()).min
  static let wordCountHardMax = resolveWordCountHardBounds(.resolve()).max

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:110
  static func findBoundaryEcho(_ body: String, _ prevBody: String?) -> String? {
    guard let prevBody, !prevBody.isEmpty else { return nil }
    let opening = Array(ProseMetrics.tokenizeWords(body).prefix(boundaryEchoWindowWords))
    let closing = Array(ProseMetrics.tokenizeWords(prevBody).suffix(boundaryEchoWindowWords))
    guard opening.count >= boundaryEchoNgramSize, closing.count >= boundaryEchoNgramSize else { return nil }
    let openingGrams = Set(ProseMetrics.ngrams(opening, boundaryEchoNgramSize))
    return ProseMetrics.ngrams(closing, boundaryEchoNgramSize).first { openingGrams.contains($0) }
  }

  private static func splitParagraphs(_ body: String) -> [String] {
    body.jsSplit(paragraphBreak).map { $0.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim() }.filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:132
  static func findDuplicatedParagraphs(_ body: String, minWords: Int = duplicateParagraphMinWords) -> [String] {
    var counts: [JSString: Int] = [:]
    var order: [String] = []
    for paragraph in splitParagraphs(body) where ProseMetrics.countWords(paragraph) >= minWords {
      let key = JSString(paragraph)
      if counts[key] == nil { order.append(paragraph) }
      counts[key, default: 0] += 1
    }
    return order.filter { counts[JSString($0), default: 0] >= 2 }
  }

  private static func excerpt(_ text: String, length: Int = 80) -> String {
    text.jsLength <= length ? text : "\(text.jsSlice(0, length))…"
  }

  private static func hard(_ text: String) -> CheckFinding { CheckFinding(severity: .hard, text: prefix + text) }
  private static func soft(_ text: String) -> CheckFinding { CheckFinding(severity: .soft, text: prefix + text) }

  private static func wordCountFinding(words: Int, target: ResolvedWordTarget) -> CheckFinding? {
    let bounds = resolveWordCountHardBounds(target)
    let count = Double(words)
    let band = "\(target.min.jsString)–\(target.max.jsString) target band"
    if count < bounds.min { return hard("draft has \(words) words of prose, below the \(bounds.min.jsString)-word floor") }
    if count > bounds.max { return hard("draft has \(words) words of prose, above the \(bounds.max.jsString)-word ceiling") }
    if count < target.min { return soft("draft has \(words) words of prose, under the \(band)") }
    if count > target.max { return soft("draft has \(words) words of prose, over the \(band)") }
    return nil
  }

  // apps/novel-forge-server/src/modules/ai/graphs/mechanical-check.ts:151
  static func checkDraftMechanics(_ markdown: String, priorMarkdown: [String] = [], target: ResolvedWordTarget = .resolve()) -> [CheckFinding] {
    var findings: [CheckFinding] = []
    let split = ChapterProse.split(markdown)
    let body = split.prose
    let priorBodies = priorMarkdown.map(ChapterProse.proseOnly)

    if let finding = wordCountFinding(words: ProseMetrics.countWords(body), target: target) { findings.append(finding) }

    if let unclosedFence = split.unclosedFence {
      findings.append(hard("the fence opened by \"\(excerpt(unclosedFence))\" is never closed, so the rest of the chapter renders inside it"))
    }

    for paragraph in findDuplicatedParagraphs(body) {
      findings.append(hard("a paragraph is repeated verbatim — \"\(excerpt(paragraph))\""))
    }

    if let echo = findBoundaryEcho(body, priorBodies.first) {
      findings.append(hard("chapter opens by repeating the previous chapter's ending verbatim — \"\(excerpt(echo))\""))
    }

    if !priorBodies.isEmpty {
      let rate = ProseMetrics.computeCrossChapterRepeatedNgrams(body, priorBodies: priorBodies).overallRepeatedRate
      if rate > crossChapterNgramRateMax {
        findings.append(soft("\((rate * 100).jsToFixed(1))% of 5–8-word phrases also appear in the previous \(priorBodies.count) chapter(s)"))
      }
    }

    let stockPhrases = ProseMetrics.computeStockPhraseCounts(body)
    if stockPhrases.total > stockPhraseMax {
      let worst = stockPhrases.hits.filter { $0.count > 0 }.jsStableSorted { $0.count > $1.count }.prefix(3).map { "\($0.label) ×\($0.count)" }.joined(separator: ", ")
      findings.append(soft("\(stockPhrases.total) stock phrases (\(worst))"))
    }

    for frame in findSimileFrameOveruse(body) {
      findings.append(
        soft(
          "the comparison frame \"\(frame.label)…\" appears \(frame.count) times (\(frame.per1000Words.jsToFixed(1)) per 1,000 words) — keep two at most and vary or cut the rest"
        ))
    }

    let tags = ProseMetrics.computeDialogueTagMetrics(body)
    if tags.tagsPer1000Words > dialogueTagsPer1000Max { findings.append(soft("\(tags.tagsPer1000Words.jsToFixed(1)) dialogue tags per 1,000 words")) }
    if tags.totalTags >= dialogueTagRateMinSample, tags.saidAlternativeRate > saidAlternativeRateMax {
      findings.append(soft("\((tags.saidAlternativeRate * 100).jsToFixed(0))% of dialogue tags avoid \"said\"/\"asked\""))
    }

    return findings
  }
}
