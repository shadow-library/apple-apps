struct NegationEcho: Sendable, Equatable {
  let terms: [String]
  let excerpt: String
}

enum NegationEchoScan: Sendable, Equatable {
  case echoes([NegationEcho])
  case unavailable
}

enum NegationRequestScan: Sendable, Equatable {
  case terms([String])
  case unavailable
}

struct NegationEchoOptions: Sendable {
  var exempt: Set<JSString> = []
}

private let nounCues: Set<JSString> = [
  "no", "without", "none", "nor", "neither", "nobody", "nothing", "nowhere", "avoid", "avoids", "avoiding", "omit", "omits", "lacks", "lacking",
]
private let pairedCues: Set<JSString> = ["free of", "instead of", "rather than", "absence of"]
private let verbalCues: Set<JSString> = ["not", "never"]
private let copulas: Set<JSString> = ["is", "are", "was", "were", "be"]
private let contractedCopulas: Set<JSString> = ["isn't", "aren't", "wasn't", "weren't"]
private let metaVerbs: Set<JSString> = [
  "mention", "mentions", "mentioned", "include", "includes", "included", "reference", "references", "referenced", "feature", "features", "featured", "show", "shows", "shown",
  "name",
  "names", "named", "describe", "describes", "described", "depict", "depicts", "depicted", "appear", "appears", "exist", "exists",
]
private let temporalFollowers: Set<JSString> = ["yet", "longer"]
private let temporalClauseMarker: JSString = "anymore"
private let forwardWindow = 6
private let backwardWindow = 2
private let minTermLength = 4
private let excerptLength = 160

private let stopwords: Set<JSString> = [
  "about", "after", "again", "also", "because", "been", "before", "being", "both", "chapter", "could", "does", "done", "each", "even", "every", "from", "have", "here", "into",
  "just", "like", "made", "make", "many", "more", "most", "much", "must", "only", "other", "over", "same", "scene", "should", "some", "such", "than", "that", "their", "them",
  "then", "there", "these", "they", "thing", "this", "those", "through", "under", "until", "very", "want", "were", "what", "when", "where", "which", "while", "will", "with",
  "within", "would", "your",
]

private struct Clause {
  let text: String
  let tokens: [String]
  let negated: [Bool]
}

struct NegationEchoDetector: Sendable {
  static let shared: NegationEchoDetector? = try? NegationEchoDetector()

  let clauseBreak: JSRegex
  let word: JSRegex
  let possessive: JSRegex
  let curlyApostrophe: JSRegex
  let capitalLetter: JSRegex
  let bullet: JSRegex
  let statementRequest: JSRegex

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:122
  init() throws(JSRegexError) {
    clauseBreak = try JSRegex(#"[.!?;:\n]+"#)
    word = try JSRegex(#"[\p{L}\p{N}]+(?:['’][\p{L}]+)*"#, flags: "gu")
    possessive = try JSRegex("'s$")
    curlyApostrophe = try JSRegex("’", flags: "g")
    capitalLetter = try JSRegex(#"^\p{Lu}"#, flags: "u")
    bullet = try JSRegex(#"^[-*•]\s*"#)
    statementRequest = try JSRegex(#"\b(?:say|says|saying|state|states|stating|rule|spell out|make (?:it )?clear|write that|note that|add a line)\b"#, flags: "i")
  }

  static func scan(before: String, after: String, options: NegationEchoOptions = NegationEchoOptions(), with detector: NegationEchoDetector? = shared) -> NegationEchoScan {
    guard let detector else { return .unavailable }
    return .echoes(detector.findNegationEchoes(before: before, after: after, options: options))
  }

  static func scanRequests(_ message: String, with detector: NegationEchoDetector? = shared) -> NegationRequestScan {
    guard let detector else { return .unavailable }
    return .terms(detector.requestedNegations(message))
  }

  private func isContractedNegation(_ token: String) -> Bool {
    token.jsEndsWith("n't")
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:130
  private func isCue(_ token: String) -> Bool {
    let key = JSString(token)
    return nounCues.contains(key) || verbalCues.contains(key) || isContractedNegation(token)
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:134
  private func normaliseTerm(_ token: String) -> String {
    let bare = token.jsReplace(possessive, "")
    if bare.jsLength > minTermLength && bare.jsEndsWith("s") && !bare.jsEndsWith("ss") { return bare.jsSlice(0, -1) }
    return bare
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:140
  private func isSalient(_ term: String) -> Bool {
    term.jsLength >= minTermLength && !stopwords.contains(JSString(term)) && !isCue(term)
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:144
  private func markWindow(_ negated: inout [Bool], from: Int, to: Int, skip: (Int) -> Bool = { _ in false }) {
    let first = max(0, from)
    let last = min(negated.count - 1, to)
    guard first <= last else { return }
    for index in first...last where !skip(index) { negated[index] = true }
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:149
  private func markCopulaSubject(_ negated: inout [Bool], _ capitalised: [Bool], copulaIndex: Int) {
    markWindow(&negated, from: copulaIndex - backwardWindow, to: copulaIndex - 1) { capitalised.indices.contains($0) && capitalised[$0] }
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:153
  private func parseClauses(_ text: String) -> [Clause] {
    text.jsSplit(clauseBreak).flatMap { raw -> [Clause] in
      let words = raw.jsMatchAll(word).map(\.text)
      if words.isEmpty { return [] }
      let tokens = words.map { $0.jsToLowerCase().jsReplace(curlyApostrophe, "'") }
      let capitalised = words.map { capitalLetter.test($0) }
      var negated = tokens.map { _ in false }
      let clauseText = raw.jsTrim().jsReplace(bullet, "")
      if tokens.contains(where: { temporalClauseMarker == JSString($0) }) { return [Clause(text: clauseText, tokens: tokens, negated: negated)] }

      for (i, token) in tokens.enumerated() {
        let next = i + 1 < tokens.count ? tokens[i + 1] : ""
        if pairedCues.contains(JSString("\(token) \(next)")) {
          markWindow(&negated, from: i + 2, to: i + 1 + forwardWindow)
          continue
        }
        if !isCue(token) || temporalFollowers.contains(JSString(next)) { continue }
        if nounCues.contains(JSString(token)) {
          markWindow(&negated, from: i + 1, to: i + forwardWindow)
          continue
        }
        if metaVerbs.contains(JSString(next)) { markWindow(&negated, from: i + 2, to: i + 1 + forwardWindow) }
        if contractedCopulas.contains(JSString(token)) {
          markCopulaSubject(&negated, capitalised, copulaIndex: i)
        } else if i >= 1 && copulas.contains(JSString(tokens[i - 1])) {
          markCopulaSubject(&negated, capitalised, copulaIndex: i - 1)
        }
      }
      return [Clause(text: clauseText, tokens: tokens, negated: negated)]
    }
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:177
  private func plainTerms(_ clauses: [Clause]) -> Set<JSString> {
    var terms = Set<JSString>()
    for clause in clauses {
      for (token, negated) in zip(clause.tokens, clause.negated) where !negated { terms.insert(JSString(normaliseTerm(token))) }
    }
    return terms
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:183
  private func excerpt(_ text: String) -> String {
    text.jsLength <= excerptLength ? text : text.jsSlice(0, excerptLength - 1).jsTrimEnd() + "…"
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:191
  func requestedNegations(_ message: String) -> [String] {
    guard statementRequest.test(message) else { return [] }
    var terms: [String] = []
    for clause in parseClauses(message) {
      for (token, negated) in zip(clause.tokens, clause.negated) where negated && isSalient(normaliseTerm(token)) { terms.append(normaliseTerm(token)) }
    }
    return terms.jsUnique()
  }

  // apps/novel-forge-server/src/modules/refinement/negation-echo.ts:199
  func findNegationEchoes(before: String, after: String, options: NegationEchoOptions = NegationEchoOptions()) -> [NegationEcho] {
    let beforePlain = plainTerms(parseClauses(before))
    let afterClauses = parseClauses(after)
    let afterPlain = plainTerms(afterClauses)
    var echoes: [NegationEcho] = []

    for clause in afterClauses {
      var found = Set<JSString>()
      var tokens: [String] = []
      for (token, negated) in zip(clause.tokens, clause.negated) {
        let term = normaliseTerm(token)
        let key = JSString(term)
        if !negated || !isSalient(term) || found.contains(key) { continue }
        if !beforePlain.contains(key) || afterPlain.contains(key) || options.exempt.contains(key) { continue }
        found.insert(key)
        tokens.append(token)
      }
      if !tokens.isEmpty { echoes.append(NegationEcho(terms: tokens, excerpt: excerpt(clause.text))) }
    }
    return echoes
  }
}
