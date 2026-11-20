import ShadowText

struct OrnatePattern: Sendable {
  let label: String
  let pattern: JSRegex
}

struct OrnateHit: Sendable {
  let label: String
  let sentence: String
}

struct ReadabilityMetrics: Sendable {
  let words: Int
  let sentenceCount: Int
  let paragraphCount: Int
  let averageSentenceWords: Double
  let longSentenceShare: Double
  let longSentences: [String]
  let averageParagraphWords: Double
  let longParagraphs: [String]
  let readingGrade: Double
  let ornateHits: [OrnateHit]
  let ornateHitsPer1000Words: Double
}

extension ProseMetrics {
  static let longSentenceWords = 30
  static let longParagraphWords = 120

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:270
  static let ornatePatterns: [OrnatePattern] = [
    OrnatePattern(
      label: "abstract noun doing concrete work",
      pattern: ProseRegex.literal(
        #"\bthe\s+(?:architecture|choreography|cartography|topography)\s+of\s+(?:his|her|their|my|our|your)\s+(?:grief|fear|anger|love|hope|guilt|shame|doubt|memory|memories|thoughts|mind|moods?|longing|regret|patience|temper|loneliness|desire|sorrow|joy|pride|silence)\b"#,
        "i"
      )
    ),
    OrnatePattern(label: "simile by manner", pattern: ProseRegex.literal(#"\bthe\s+way\s+one\s+(?!of\b)\w+s\b"#, "i")),
    OrnatePattern(label: "narrator cleverness", pattern: ProseRegex.literal(#"\b(?:the\s+universe|fate)['’]s\s+idea\s+of\s+a\s+joke\b"#, "i")),
    OrnatePattern(label: "metaphor for a voice", pattern: ProseRegex.literal(#"\bvoice\s+like\s+(?:a|an)\s+\w+"#, "i")),
    OrnatePattern(
      label: "metaphor for a silence",
      pattern: ProseRegex.literal(#"\b(?:silence|stillness)\s+(?:had|held|carried)\s+(?:a|an)\s+(?:weight|texture|shape|taste|colou?r|temperature)\b"#, "i")
    ),
    OrnatePattern(label: "metaphor for a room", pattern: ProseRegex.literal(#"\bthe\s+(?:room|office|hall|house|kitchen)\s+held\s+its\s+breath\b"#, "i")),
  ]

  private static let abbreviations: Set<JSString> = [
    "mr", "mrs", "ms", "dr", "st", "jr", "sr", "prof", "capt", "lt", "sgt", "col", "gen", "mt", "vs", "etc", "no", "e.g", "i.e", "a.m", "p.m",
  ]
  private static let sentenceEnd = ProseRegex.literal(#"[.!?]+["'”’)\]]*(?=\s|$)"#, "g")
  private static let openingQuotes = ProseRegex.literal(#"^["'“‘(]+"#)
  private static let singleCapital = ProseRegex.literal(#"^[A-Z]$"#)
  private static let alphanumeric = ProseRegex.literal(#"[A-Za-z0-9]"#)
  private static let letter = ProseRegex.literal(#"[A-Za-z]"#)
  private static let lineBreakRun = ProseRegex.literal(#"\n+"#)
  private static let nonLetters = ProseRegex.literal(#"[^a-z]"#, "g")
  private static let silentEnding = ProseRegex.literal(#"(?:[^laeiouy]es|ed|[^laeiouy]e)$"#)
  private static let leadingY = ProseRegex.literal(#"^y"#)
  private static let vowelGroup = ProseRegex.literal(#"[aeiouy]{1,2}"#, "g")

  private static func endsInAbbreviation(_ text: String) -> Bool {
    let word = (text.jsTrimEnd().jsSplit(ProseRegex.whitespaceRun).last ?? "").jsReplace(openingQuotes, "")
    return abbreviations.contains(JSString(word.jsToLowerCase())) || singleCapital.test(word)
  }

  private static func proseSentences(_ paragraph: String) -> [String] {
    let units = paragraph.jsCodeUnits
    var sentences: [String] = []
    var start = 0
    for match in paragraph.jsMatchAll(sentenceEnd) {
      if match.text.jsEquals("."), endsInAbbreviation(JSText.string(fromCodeUnits: units[start..<match.index])) { continue }
      sentences.append(JSText.string(fromCodeUnits: units[start..<match.endIndex]))
      start = match.endIndex
    }
    sentences.append(JSText.string(fromCodeUnits: units[start...]))
    return sentences.map { $0.jsTrim() }.filter { alphanumeric.test($0) }
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:333
  static func splitProseParagraphs(_ body: String) -> [String] {
    body.jsSplit(lineBreakRun).map { $0.jsReplace(ProseRegex.whitespaceRunGlobal, " ").jsTrim() }.filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:342
  static func countSyllables(_ word: String) -> Int {
    let letters = word.jsToLowerCase().jsReplace(nonLetters, "")
    if letters.isEmpty { return 0 }
    if letters.jsLength <= 3 { return 1 }
    let stem = letters.jsReplace(silentEnding, "").jsReplace(leadingY, "")
    return max(1, stem.jsMatchAll(vowelGroup).count)
  }

  private static func byWordsDescending(_ texts: [String]) -> [String] {
    texts.map { (text: $0, words: countWords($0)) }.jsStableSorted { $0.words > $1.words }.map(\.text)
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:354
  static func computeReadabilityMetrics(_ body: String, patterns: [OrnatePattern] = ornatePatterns) -> ReadabilityMetrics {
    let prose = ChapterProse.proseOnly(body)
    let paragraphs = splitProseParagraphs(prose)
    let sentences = paragraphs.flatMap(proseSentences)
    let sentenceWords = sentences.map(countWords)
    let words = sentenceWords.reduce(0, +)
    let letterWords = sentences.flatMap { $0.jsSplit(ProseRegex.whitespaceRun) }.filter { letter.test($0) }
    let syllables = letterWords.reduce(0) { $0 + countSyllables($1) }
    let longSentences = sentences.indices.filter { sentenceWords[$0] > longSentenceWords }.map { sentences[$0] }
    var cursors = patterns.map { JSRegexCursor($0.pattern) }
    var ornateHits: [OrnateHit] = []
    for sentence in sentences {
      guard let hit = patterns.indices.first(where: { cursors[$0].test(sentence) }) else { continue }
      ornateHits.append(OrnateHit(label: patterns[hit].label, sentence: sentence))
    }
    let sentenceCount = Double(sentences.count)
    return ReadabilityMetrics(
      words: words,
      sentenceCount: sentences.count,
      paragraphCount: paragraphs.count,
      averageSentenceWords: sentences.isEmpty ? 0 : Double(words) / sentenceCount,
      longSentenceShare: sentences.isEmpty ? 0 : Double(longSentences.count) / sentenceCount,
      longSentences: byWordsDescending(longSentences),
      averageParagraphWords: paragraphs.isEmpty ? 0 : Double(countWords(prose)) / Double(paragraphs.count),
      longParagraphs: byWordsDescending(paragraphs.filter { countWords($0) > longParagraphWords }),
      readingGrade: sentences.isEmpty || letterWords.isEmpty
        ? 0 : 0.39 * (Double(words) / sentenceCount) + 11.8 * (Double(syllables) / Double(letterWords.count)) - 15.59,
      ornateHits: ornateHits,
      ornateHitsPer1000Words: words == 0 ? 0 : Double(ornateHits.count) / Double(words) * 1000
    )
  }
}
