import ShadowText

struct WordCountReport: Equatable, Sendable {
  let chapter: Int
  let words: Int
  let inTarget: Bool
}

struct WordCountSummary: Equatable, Sendable {
  let chapters: [WordCountReport]
  let count: Int
  let inTargetCount: Int
  let inTargetRate: Double
  let min: Int
  let max: Int
  let mean: Double
  let median: Double
}

struct ChapterBody: Sendable {
  let chapter: Int
  let body: String
}

enum ProseMetrics {
  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:167
  static func countWords(_ text: String) -> Int {
    let trimmed = text.jsTrim()
    if trimmed.isEmpty { return 0 }
    return trimmed.jsSplit(ProseRegex.whitespaceRun).count
  }

  static func countProseWords(_ markdown: String) -> Int {
    countWords(ChapterProse.proseOnly(markdown))
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:194
  static func computeWordCountDistribution(_ chapters: [ChapterBody], target: ResolvedWordTarget = .resolve()) -> WordCountSummary {
    let reports = chapters.map { chapter in
      let words = countProseWords(chapter.body)
      return WordCountReport(chapter: chapter.chapter, words: words, inTarget: target.contains(words))
    }
    let counts = reports.map(\.words).sorted()
    let count = counts.count
    let mid = count / 2
    let median = count == 0 ? 0 : count % 2 == 0 ? Double(counts[mid - 1] + counts[mid]) / 2 : Double(counts[mid])
    let inTargetCount = reports.filter(\.inTarget).count
    return WordCountSummary(
      chapters: reports,
      count: count,
      inTargetCount: inTargetCount,
      inTargetRate: count == 0 ? 0 : Double(inTargetCount) / Double(count),
      min: counts.first ?? 0,
      max: counts.last ?? 0,
      mean: count == 0 ? 0 : counts.reduce(0.0) { $0 + Double($1) } / Double(count),
      median: median
    )
  }
}
