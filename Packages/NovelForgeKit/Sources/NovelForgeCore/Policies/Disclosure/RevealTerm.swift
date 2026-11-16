// apps/novel-forge-server/src/common/reveal-term.ts:4
private let minRevealTermLength = 3

private let uppercaseLetter = ProseRegex.literal(#"\p{Lu}"#, "u")

// apps/novel-forge-server/src/common/reveal-term.ts:11
func revealTermPattern(_ term: String, global: Bool = false) throws(DisclosureError) -> JSRegex? {
  let trimmed = term.jsTrim()
  guard trimmed.jsLength >= minRevealTermLength else { return nil }
  let flags = (global ? "g" : "") + (uppercaseLetter.test(trimmed) ? "u" : "iu")
  do {
    return try JSRegex(#"(?<![\p{L}\p{N}_])"# + JSRegex.escape(trimmed) + #"(?![\p{L}\p{N}_])"#, flags: flags)
  } catch {
    throw .pattern(error)
  }
}

// apps/novel-forge-server/src/common/reveal-term.ts:19
func cluesNamingTerms(_ clues: [String]?, _ terms: [String]?) throws(DisclosureError) -> [String] {
  var patterns: [(term: String, pattern: JSRegex)] = []
  for term in terms ?? [] {
    if let pattern = try revealTermPattern(term) { patterns.append((term.jsTrim(), pattern)) }
  }
  return (clues ?? []).flatMap { clue in patterns.filter { $0.pattern.test(clue) }.map { "\"\(clue)\" names \"\($0.term)\"" } }
}

struct ClueTermFields: Equatable, Sendable {
  var allowedClues: [String]?
  var terms: [String]?
}

private func sameList(_ left: [String]?, _ right: [String]?) -> Bool {
  let (a, b) = (left ?? [], right ?? [])
  return a.count == b.count && zip(a, b).allSatisfy { $0.jsEquals($1) }
}

// apps/novel-forge-server/src/common/reveal-term.ts:39
func changedCluesNamingTerms(before: ClueTermFields?, after: ClueTermFields) throws(DisclosureError) -> [String] {
  if let before, sameList(before.allowedClues, after.allowedClues), sameList(before.terms, after.terms) { return [] }
  return try cluesNamingTerms(after.allowedClues, after.terms)
}

// apps/novel-forge-server/src/common/open-canon.ts:5
let openFromChapter = 1

// apps/novel-forge-server/src/common/open-canon.ts:7
func isOpenCanon(_ revealChapter: Int?) -> Bool {
  revealChapter.map { $0 <= openFromChapter } ?? false
}
