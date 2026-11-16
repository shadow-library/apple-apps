struct StockPhrase: Sendable {
  let label: String
  let pattern: JSRegex
}

struct StockPhraseHit: Equatable, Sendable {
  let label: String
  let count: Int
}

struct StockPhraseReport: Equatable, Sendable {
  let hits: [StockPhraseHit]
  let total: Int
}

struct DialogueTagMetrics: Equatable, Sendable {
  let totalTags: Int
  let saidAskedCount: Int
  let alternativeCount: Int
  let saidAlternativeRate: Double
  let tagsPer1000Words: Double
}

struct ContractionRateReport: Equatable, Sendable {
  let contracted: Int
  let expanded: Int
  let rate: Double
}

struct ContractionPair: Sendable {
  let contracted: String
  let expanded: String
}

struct ContractionMatchers: Sendable {
  private let patterns: [(contracted: JSRegex, expanded: JSRegex)]

  private static let apostrophe = ProseRegex.literal("'", "g")

  init(pairs: [ContractionPair]) throws(JSRegexError) {
    var patterns: [(contracted: JSRegex, expanded: JSRegex)] = []
    for pair in pairs {
      let contractedSource = pair.contracted.jsReplace(Self.apostrophe, "['’]")
      patterns.append((contracted: try JSRegex(#"\b"# + contractedSource + #"\b"#, flags: "gi"), expanded: try JSRegex(#"\b"# + pair.expanded + #"\b"#, flags: "gi")))
    }
    self.patterns = patterns
  }

  func count(in dialogue: String) -> (contracted: Int, expanded: Int) {
    var totals = (contracted: 0, expanded: 0)
    for pair in patterns {
      totals.contracted += dialogue.jsMatchAll(pair.contracted).count
      totals.expanded += dialogue.jsMatchAll(pair.expanded).count
    }
    return totals
  }
}

extension ProseMetrics {
  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:73
  static let stockPhrases: [StockPhrase] = [
    ("narrowed eyes", #"\b(?:eyes narrowed|narrowed (?:his|her|their) eyes)\b"#),
    ("tightened jaw", #"\b(?:jaw tightened|tightened (?:his|her|their) jaw)\b"#),
    ("breath hitched", #"\bbreath hitched\b"#),
    ("mixture of X and Y", #"\ba mixture of \w+ and \w+\b"#),
    ("heart pounded/pounding", #"\bheart (?:pounded|was pounding|pounding)\b"#),
    ("let out a breath they didn't know", #"\blet out (?:a|the) breath (?:he|she|they) (?:didn't|did not) (?:know|realize)"#),
    ("eyes widened", #"\beyes widened\b"#),
    ("voice barely above a whisper", #"\bvoice(?:,)? barely (?:above|more than) a whisper\b"#),
    ("shiver(s) down (his/her) spine", #"\bshiver(?:s)? (?:ran |went )?down (?:his|her|their) spine\b"#),
    ("clenched fists", #"\bclenched (?:his|her|their) fist"#),
    ("stomach dropped", #"\bstomach dropped\b"#),
    ("blood ran cold", #"\bblood ran cold\b"#),
    ("time seemed to slow", #"\btime seemed to (?:slow|stop|stand still)\b"#),
    ("world seemed to stop/freeze", #"\b(?:world|everything) seemed to (?:stop|freeze)\b"#),
    ("couldn't help but", #"\bcouldn't help but\b"#),
    ("ghost of a smile", #"\b(?:a ghost of a smile|ghost of a smile)\b"#),
    ("let out a sigh", #"\blet out a (?:heavy |long |quiet )?sigh\b"#),
    ("eyes flickered", #"\beyes flickered\b"#),
    ("swallowed hard/the lump", #"\bswallowed (?:hard|the lump in (?:his|her|their) throat)\b"#),
    ("raised an eyebrow", #"\braised an eyebrow\b"#),
    (
      "released a breath",
      #"\breleased (?:a|the) breath (?:she|he|they) (?:didn't|did not) (?:know|realize) (?:she|he|they) (?:was|were) holding\b"#
    ),
  ].map { StockPhrase(label: $0.0, pattern: ProseRegex.literal($0.1, "gi")) }

  private static let saidAskedVerbs = ["said", "asked"]

  private static let saidAlternativeVerbs = [
    "exclaimed", "growled", "whispered", "shouted", "muttered", "hissed", "snapped", "murmured", "replied", "answered", "demanded", "insisted", "breathed",
    "gasped", "sighed", "warned", "protested", "agreed", "countered", "continued", "added", "interrupted", "laughed",
  ]

  private static let dialogueTagPattern = ProseRegex.literal(
    #"["”]\s*,?\s*(?:[A-Z][a-z]+(?:\s[A-Z][a-z]+)?\s)?("# + (saidAskedVerbs + saidAlternativeVerbs).joined(separator: "|") + #")\b"#,
    "gi"
  )
  private static let quotedSpan = ProseRegex.literal(#"["“]([^"”]*)["”]"#, "g")

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:129
  static let contractionPairs: [ContractionPair] = [
    ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"), ("can't", "cannot"), ("couldn't", "could not"), ("won't", "will not"),
    ("wouldn't", "would not"), ("shouldn't", "should not"), ("isn't", "is not"), ("aren't", "are not"), ("wasn't", "was not"), ("weren't", "were not"),
    ("hasn't", "has not"), ("haven't", "have not"), ("hadn't", "had not"), ("I'm", "I am"), ("you're", "you are"), ("he's", "he is"), ("she's", "she is"),
    ("it's", "it is"), ("we're", "we are"), ("they're", "they are"), ("I've", "I have"), ("you've", "you have"), ("we've", "we have"),
    ("they've", "they have"), ("I'll", "I will"), ("you'll", "you will"), ("he'll", "he will"), ("she'll", "she will"), ("we'll", "we will"),
    ("they'll", "they will"), ("that's", "that is"), ("there's", "there is"), ("let's", "let us"),
  ].map { ContractionPair(contracted: $0.0, expanded: $0.1) }

  static let standardContractionMatchers: ContractionMatchers = {
    do {
      return try ContractionMatchers(pairs: contractionPairs)
    } catch {
      preconditionFailure("the reference contraction patterns do not compile: \(error)")
    }
  }()

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:461
  static func computeStockPhraseCounts(_ body: String, phrases: [StockPhrase] = stockPhrases) -> StockPhraseReport {
    let hits = phrases.map { phrase in
      let matches = body.jsMatchAll(phrase.pattern)
      let count = phrase.pattern.global ? matches.count : matches.first.map { 1 + $0.groups.count } ?? 0
      return StockPhraseHit(label: phrase.label, count: count)
    }
    return StockPhraseReport(hits: hits, total: hits.reduce(0) { $0 + $1.count })
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:479
  static func computeDialogueTagMetrics(_ body: String) -> DialogueTagMetrics {
    let alternatives = Set(saidAlternativeVerbs.map { JSString($0.jsToLowerCase()) })
    let matches = body.jsMatchAll(dialogueTagPattern)
    let alternativeCount = matches.filter { alternatives.contains(JSString(($0.groups[0] ?? "").jsToLowerCase())) }.count
    let totalTags = matches.count
    let words = countWords(body)
    return DialogueTagMetrics(
      totalTags: totalTags,
      saidAskedCount: totalTags - alternativeCount,
      alternativeCount: alternativeCount,
      saidAlternativeRate: totalTags == 0 ? 0 : Double(alternativeCount) / Double(totalTags),
      tagsPer1000Words: words == 0 ? 0 : Double(totalTags) / Double(words) * 1000
    )
  }

  private static func extractQuotedSpans(_ body: String) -> String {
    body.jsMatchAll(quotedSpan).map(\.text).joined(separator: " ")
  }

  // apps/novel-forge-server/src/modules/eval/deterministic-metrics.ts:511
  static func computeDialogueContractionRate(_ body: String, matchers: ContractionMatchers = standardContractionMatchers) -> ContractionRateReport {
    let (contracted, expanded) = matchers.count(in: extractQuotedSpans(body))
    return ContractionRateReport(contracted: contracted, expanded: expanded, rate: contracted + expanded == 0 ? 0 : Double(contracted) / Double(contracted + expanded))
  }
}
