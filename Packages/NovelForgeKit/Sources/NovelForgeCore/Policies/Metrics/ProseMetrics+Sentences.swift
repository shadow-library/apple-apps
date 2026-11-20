import ShadowText

struct SentenceLengthMetrics: Equatable, Sendable {
  let sentenceCount: Int
  let bandCount: Int
  let bandRate: Double
  let longestMonotonyRun: Int
  let lengths: [Int]
}

extension ProseMetrics {
  static let sentenceBandMin = 6
  static let sentenceBandMax = 22

  private static let sentencePattern = ProseRegex.literal(#"[^.!?]+[.!?]+(?=\s|$)|[^.!?]+$"#, "g")

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:218
  static func splitSentences(_ text: String) -> [String] {
    let normalized = text.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim()
    if normalized.isEmpty { return [] }
    return normalized.jsMatchAll(sentencePattern).map { $0.text.jsTrim() }.filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:233
  static func computeSentenceLengthMetrics(_ body: String) -> SentenceLengthMetrics {
    let sentences = splitSentences(body)
    let lengths = sentences.map(countWords)
    let inBand = lengths.map { $0 >= sentenceBandMin && $0 <= sentenceBandMax }
    var longestRun = 0
    var currentRun = 0
    for ok in inBand {
      if ok {
        currentRun = 0
      } else {
        currentRun += 1
        longestRun = max(longestRun, currentRun)
      }
    }
    let bandCount = inBand.filter { $0 }.count
    return SentenceLengthMetrics(
      sentenceCount: sentences.count,
      bandCount: bandCount,
      bandRate: sentences.isEmpty ? 0 : Double(bandCount) / Double(sentences.count),
      longestMonotonyRun: longestRun,
      lengths: lengths
    )
  }
}
