import ShadowText

struct FlaggedSentence: Equatable, Sendable {
  let sentence: String
  let reason: String
}

struct ReadabilityEvidence: Sendable {
  let metrics: ReadabilityMetrics
  let overLimits: [String]
  let flagged: [FlaggedSentence]
}

enum ReadabilityCheck {
  static let prefix = "readability: "
  static let minWords = 400
  static let averageSentenceWordsMax = 20.0
  static let longSentenceShareMax = 0.1
  static let averageParagraphWordsMax = 70.0
  static let readingGradeMax = 9.0
  static let ornateHitsPer1000WordsMax = 1.0
  static let ornateHitsMin = 3

  private static let flaggedSentencesMax = 5
  private static let quoteCharsMax = 400

  private static func quote(_ text: String) -> String {
    "\"\(text.jsLength <= quoteCharsMax ? text : "\(text.jsSlice(0, quoteCharsMax))…")\""
  }

  private static func percent(_ share: Double) -> String {
    "\((share * 100).jsToFixed(0))%"
  }

  private static func overLimits(_ metrics: ReadabilityMetrics) -> [String] {
    var crossed: [String] = []
    if metrics.averageSentenceWords > averageSentenceWordsMax {
      crossed.append("average sentence \(metrics.averageSentenceWords.jsToFixed(1)) words (limit \(averageSentenceWordsMax.jsString))")
    }
    if metrics.longSentenceShare > longSentenceShareMax {
      crossed.append("sentences over \(ProseMetrics.longSentenceWords) words \(percent(metrics.longSentenceShare)) (limit \(percent(longSentenceShareMax)))")
    }
    if metrics.averageParagraphWords > averageParagraphWordsMax {
      crossed.append("average paragraph \(metrics.averageParagraphWords.jsToFixed(0)) words (limit \(averageParagraphWordsMax.jsString))")
    }
    if metrics.readingGrade > readingGradeMax { crossed.append("reading grade \(metrics.readingGrade.jsToFixed(1)) (limit \(readingGradeMax.jsString))") }
    if metrics.ornateHits.count >= ornateHitsMin, metrics.ornateHitsPer1000Words > ornateHitsPer1000WordsMax {
      crossed.append("ornate constructions \(metrics.ornateHitsPer1000Words.jsToFixed(1)) per 1,000 words (limit \(ornateHitsPer1000WordsMax.jsString))")
    }
    return crossed
  }

  // apps/novel-forge-server/src/modules/ai/graphs/readability-check.ts:73
  static func assessReadability(_ body: String) -> ReadabilityEvidence? {
    let metrics = ProseMetrics.computeReadabilityMetrics(body)
    if metrics.words < minWords { return nil }
    let ornate = metrics.ornateHits.map { FlaggedSentence(sentence: $0.sentence, reason: $0.label) }
    let long = metrics.longSentences.map { FlaggedSentence(sentence: $0, reason: "over \(ProseMetrics.longSentenceWords) words") }
    return ReadabilityEvidence(metrics: metrics, overLimits: overLimits(metrics), flagged: Array((ornate + long).prefix(flaggedSentencesMax)))
  }

  private static func measurements(_ evidence: ReadabilityEvidence) -> String {
    let metrics = evidence.metrics
    return [
      "\(metrics.words) words",
      "average sentence \(metrics.averageSentenceWords.jsToFixed(1)) words",
      "sentences over \(ProseMetrics.longSentenceWords) words \(percent(metrics.longSentenceShare))",
      "average paragraph \(metrics.averageParagraphWords.jsToFixed(0)) words",
      "reading grade \(metrics.readingGrade.jsToFixed(1))",
      "ornate constructions \(metrics.ornateHits.count) (\(metrics.ornateHitsPer1000Words.jsToFixed(1)) per 1,000 words)",
    ].joined(separator: " · ")
  }

  // apps/novel-forge-server/src/modules/ai/graphs/readability-check.ts:84
  static func renderReadabilityEvidence(_ evidence: ReadabilityEvidence) -> String {
    var lines = [
      "## READABILITY EVIDENCE", measurements(evidence), "Over the default's limits: \(evidence.overLimits.isEmpty ? "none" : evidence.overLimits.joined(separator: "; "))",
    ]
    if !evidence.flagged.isEmpty {
      lines.append("Flagged sentences:")
      lines.append(contentsOf: evidence.flagged.enumerated().map { "\($0.offset + 1). \(quote($0.element.sentence)) (\($0.element.reason))" })
    }
    return lines.joined(separator: "\n")
  }

  // apps/novel-forge-server/src/modules/ai/graphs/readability-check.ts:93
  static func readabilityNote(_ evidence: ReadabilityEvidence?) -> String? {
    guard let evidence, !evidence.overLimits.isEmpty else { return nil }
    return "[info] \(prefix)measured \(measurements(evidence)); over the default's limits: \(evidence.overLimits.joined(separator: "; "))"
  }
}
