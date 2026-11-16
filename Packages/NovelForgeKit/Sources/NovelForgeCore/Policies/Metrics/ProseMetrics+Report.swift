struct ChapterMetricsInput: Sendable {
  let chapter: Int
  let body: String
  let hookType: String?
}

struct ChapterMetricsReport: Sendable {
  let chapter: Int
  let words: Int
  let inWordTarget: Bool
  let sentence: SentenceLengthMetrics
  let withinChapterNgrams: NgramReport
  let crossChapterNgrams: NgramReport
  let stockPhrases: StockPhraseReport
  let dialogueTags: DialogueTagMetrics
  let contractionRate: ContractionRateReport
  let readability: ReadabilityMetrics
  let hookType: String?
}

struct DeterministicMetricsReport: Sendable {
  let chapters: [ChapterMetricsReport]
  let wordCountSummary: WordCountSummary
  let endingModeDistribution: EndingModeDistribution
}

extension ProseMetrics {
  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:560
  static func computeChapterMetrics(_ input: ChapterMetricsInput, priorBodies: [String], target: ResolvedWordTarget = .resolve()) -> ChapterMetricsReport {
    let prose = ChapterProse.proseOnly(input.body)
    let words = countWords(prose)
    return ChapterMetricsReport(
      chapter: input.chapter,
      words: words,
      inWordTarget: target.contains(words),
      sentence: computeSentenceLengthMetrics(prose),
      withinChapterNgrams: computeWithinChapterRepeatedNgrams(prose),
      crossChapterNgrams: computeCrossChapterRepeatedNgrams(prose, priorBodies: priorBodies.map(ChapterProse.proseOnly)),
      stockPhrases: computeStockPhraseCounts(prose),
      dialogueTags: computeDialogueTagMetrics(prose),
      contractionRate: computeDialogueContractionRate(prose),
      readability: computeReadabilityMetrics(prose),
      hookType: input.hookType
    )
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:588
  static func computeDeterministicMetricsReport(
    _ chapters: [ChapterMetricsInput],
    priorBodiesByChapter: [Int: [String]],
    target: ResolvedWordTarget = .resolve()
  ) -> DeterministicMetricsReport {
    DeterministicMetricsReport(
      chapters: chapters.map { computeChapterMetrics($0, priorBodies: priorBodiesByChapter[$0.chapter] ?? [], target: target) },
      wordCountSummary: computeWordCountDistribution(chapters.map { ChapterBody(chapter: $0.chapter, body: $0.body) }, target: target),
      endingModeDistribution: computeEndingModeDistribution(chapters.map { EndingModeEntry(chapter: $0.chapter, hookType: $0.hookType) })
    )
  }
}
