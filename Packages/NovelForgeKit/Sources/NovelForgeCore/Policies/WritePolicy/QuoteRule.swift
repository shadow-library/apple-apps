/// A content word as UTF-16 code units: a bigram of a spaceless run can hold half a surrogate pair, which no Swift string keeps.
typealias QuoteToken = [UInt16]

// apps/novel-forge-server/src/modules/refinement/write-policy.ts:259
struct AuthorWords: Sendable, Equatable {
  let stated: Set<QuoteToken>
  let hedged: Set<QuoteToken>
}

struct QuoteRule: Sendable {
  static let shared: QuoteRule? = try? QuoteRule()

  let hedgeCue: JSRegex
  let negationCue: JSRegex
  let rejectionCue: JSRegex
  let clauseBreak: JSRegex
  let trailingClosers: JSRegex
  let sentenceBreak: JSRegex
  let spacelessScript: JSRegex
  let singleQuotes: JSRegex
  let doubleQuotes: JSRegex
  let dashes: JSRegex
  let whitespaceRun: JSRegex
  let quoteMarks: JSRegex
  let word: JSRegex
  let possessive: JSRegex

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:165
  init() throws(JSRegexError) {
    hedgeCue = try JSRegex(
      #"\b(if|maybe|perhaps|might|could|probably|possibly|wonder|whether|suppose|imagine|not sure|or should)\b|也许|或许|可能|大概|如果|要是|もし|かもしれ|たぶん|多分|아마|만약"#
    )
    negationCue = try JSRegex(#"\b(not|no|never|without|nor|cannot)\b|n't\b|不是|没有|沒有|并非|ではない|じゃない|아니"#)
    rejectionCue = try JSRegex(#"\b(bad idea|terrible idea|no way|scrap|drop that|instead)\b"#)
    clauseBreak = try JSRegex(#"[,;:()、]|\s-\s"#)
    trailingClosers = try JSRegex(#"["'”’)\]」』\s]+$"#)
    sentenceBreak = try JSRegex(#"(?<=[.!?]["'”’)\]]*)\s+|(?<=[。！？][」』"'”’)]*)(?![」』"'”’)])|\n+"#)
    spacelessScript = try JSRegex(#"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー]+"#, flags: "gu")
    singleQuotes = try JSRegex("[‘’‛ʼ]", flags: "g")
    doubleQuotes = try JSRegex("[“”‟]", flags: "g")
    dashes = try JSRegex("[–—]", flags: "g")
    whitespaceRun = try JSRegex(#"\s+"#, flags: "g")
    quoteMarks = try JSRegex(#"^["'\s]+|["'\s]+$"#, flags: "g")
    word = try JSRegex(#"[\p{L}\p{N}]+(?:'[\p{L}]+)?"#, flags: "gu")
    possessive = try JSRegex("'s$")
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:183
  func normaliseForQuote(_ text: String) -> String {
    text.jsNormalize(.nfkc).jsToLowerCase()
      .jsReplace(singleQuotes, "'")
      .jsReplace(doubleQuotes, "\"")
      .jsReplace(dashes, "-")
      .jsReplace(whitespaceRun, " ")
      .jsTrim()
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:194
  func trimQuoteMarks(_ quote: String) -> String {
    quote.jsReplace(quoteMarks, "")
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:210
  func contentTokens(_ text: String) -> [QuoteToken] {
    let normalised = normaliseForQuote(text)
    let units = normalised.jsCodeUnits
    let spaceless = normalised.jsMatchAll(spacelessScript).flatMap { run in Self.bigrams(units[run.index..<run.endIndex]) }
    let words = normalised.jsReplace(spacelessScript, " ").jsMatchAll(word).map(\.text)
    let spaced = words.map { $0.jsReplace(possessive, "") }
      .filter { $0.jsLength > 1 && !WritePolicyTables.quoteStopwords.contains(JSString($0)) }
      .map { Self.stem($0).jsCodeUnits }
    return spaced + spaceless
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:221
  func splitSentences(_ text: String) -> [String] {
    text.jsSplit(sentenceBreak).map(normaliseForQuote).filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:229
  func sentenceIsTentative(_ sentence: String) -> Bool {
    sentence.jsReplace(trailingClosers, "").jsEndsWith("?") || hedgeCue.test(sentence) || rejectionCue.test(sentence)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:234
  func quoteFoundIn(_ quote: String, _ text: String) -> Bool {
    let needle = normaliseForQuote(trimQuoteMarks(quote))
    if contentTokens(needle).count < WritePolicyTables.minQuoteWords { return false }
    return normaliseForQuote(text).jsIncludes(needle)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:241
  func quoteIsTentative(_ quote: String, _ text: String) -> Bool {
    let needle = normaliseForQuote(trimQuoteMarks(quote))
    let candidates = splitSentences(text) + [normaliseForQuote(text)]
    guard let sentence = candidates.first(where: { $0.jsIncludes(needle) }), !sentence.isEmpty else { return false }
    let at = sentence.jsIndexOf(needle)
    let clause = sentence.jsSlice(0, at).jsSplit(clauseBreak).last ?? ""
    let after = sentence.jsSlice(at + needle.jsLength)
    let asked = sentence.jsReplace(trailingClosers, "").jsEndsWith("?") || hedgeCue.test(sentence)
    return asked || negationCue.test(clause) || rejectionCue.test(after)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:266
  func authorWords(_ vocabulary: String) -> AuthorWords {
    let sentences = splitSentences(vocabulary)
    let tentative = sentences.map(sentenceIsTentative)
    let stated = Set(zip(sentences, tentative).filter { !$0.1 }.flatMap { contentTokens($0.0) })
    let hedged = Set(zip(sentences, tentative).filter(\.1).flatMap { contentTokens($0.0) }.filter { !stated.contains($0) })
    return AuthorWords(stated: stated, hedged: hedged)
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:198
  private static func stem(_ word: String) -> String {
    if word.jsLength > 4, word.jsEndsWith("ies") { return "\(word.jsSlice(0, -3))y" }
    if word.jsLength > 4, word.jsEndsWith("s"), !word.jsEndsWith("ss") { return word.jsSlice(0, -1) }
    return word
  }

  // apps/novel-forge-server/src/modules/refinement/write-policy.ts:205
  private static func bigrams(_ run: ArraySlice<UInt16>) -> [QuoteToken] {
    if run.count < 2 { return [Array(run)] }
    return zip(run, run.dropFirst()).map { [$0, $1] }
  }
}
