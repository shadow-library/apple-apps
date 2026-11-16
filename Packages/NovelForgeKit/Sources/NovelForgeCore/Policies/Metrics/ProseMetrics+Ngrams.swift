struct NgramSizeStat: Equatable, Sendable {
  let n: Int
  let totalOccurrences: Int
  let repeatedOccurrences: Int
  let repeatedRate: Double
}

struct NgramReport: Equatable, Sendable {
  let sizes: [NgramSizeStat]
  let overallRepeatedRate: Double
}

extension ProseMetrics {
  static let ngramSizes = [5, 6, 7, 8]

  private static let nonTokenCharacters = ProseRegex.literal(#"[^a-z0-9']+"#, "g")

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:385
  static func tokenizeWords(_ text: String) -> [String] {
    text.jsToLowerCase().jsSplit(ProseRegex.whitespaceRun).map { $0.jsReplace(nonTokenCharacters, "") }.filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:395
  static func ngrams(_ tokens: [String], _ n: Int) -> [String] {
    guard n >= 1, tokens.count >= n else { return [] }
    return (0...(tokens.count - n)).map { tokens[$0..<($0 + n)].joined(separator: " ") }
  }

  private static func report(_ sizeStats: [NgramSizeStat]) -> NgramReport {
    let totalOccurrences = sizeStats.reduce(0) { $0 + $1.totalOccurrences }
    let totalRepeated = sizeStats.reduce(0) { $0 + $1.repeatedOccurrences }
    return NgramReport(sizes: sizeStats, overallRepeatedRate: totalOccurrences == 0 ? 0 : Double(totalRepeated) / Double(totalOccurrences))
  }

  private static func stat(n: Int, grams: [String], repeatedOccurrences: Int) -> NgramSizeStat {
    NgramSizeStat(
      n: n,
      totalOccurrences: grams.count,
      repeatedOccurrences: repeatedOccurrences,
      repeatedRate: grams.isEmpty ? 0 : Double(repeatedOccurrences) / Double(grams.count)
    )
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:415
  static func computeWithinChapterRepeatedNgrams(_ body: String, sizes: [Int] = ngramSizes) -> NgramReport {
    let tokens = tokenizeWords(body)
    return report(
      sizes.map { n in
        let grams = ngrams(tokens, n)
        var counts: [String: Int] = [:]
        for gram in grams { counts[gram, default: 0] += 1 }
        return stat(n: n, grams: grams, repeatedOccurrences: grams.filter { counts[$0, default: 0] >= 2 }.count)
      })
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:430
  static func computeCrossChapterRepeatedNgrams(_ body: String, priorBodies: [String], sizes: [Int] = ngramSizes) -> NgramReport {
    let tokens = tokenizeWords(body)
    let priorTokens = priorBodies.map(tokenizeWords)
    var priorGramsBySize: [Int: Set<String>] = [:]
    for n in sizes {
      var grams = Set<String>()
      for prior in priorTokens { grams.formUnion(ngrams(prior, n)) }
      priorGramsBySize[n] = grams
    }
    return report(
      sizes.map { n in
        let grams = ngrams(tokens, n)
        let prior = priorGramsBySize[n] ?? []
        return stat(n: n, grams: grams, repeatedOccurrences: grams.filter { prior.contains($0) }.count)
      })
  }
}
