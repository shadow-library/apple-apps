import ShadowText

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:298
let knowledgeLeakPrefix = "knowledge leak: "

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:299
let overConnectionMarker = "over-connection:"

private let unknowableReveal = "cut anything that states or implies what the POV cast cannot know yet"
private let solvedClue = "leave the clues unexplained: cut the narration, dialogue or action that links them to a conclusion the POV cast has not discovered on-page"
private let excerptRadius = 60

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:60
struct KnowledgeLeakIssue: Equatable, Sendable {
  let factKey: String
  let term: String
  /// Sliced by code unit as the reference does; where that cuts a surrogate pair the dangling half is dropped.
  let excerpt: String
}

struct PrescanLeak: Equatable, Sendable {
  let factKey: String
  let term: String
}

/// A judge finding as the reference holds it. `opensWithLoneSurrogate` marks a finding the reference sliced inside a surrogate pair (a capital İ earlier on the line lowers to two
/// code units): its first code unit is half a pair, which no trim removes and no marker or key can match, and `text` is the rest.
struct JudgeIssue: Equatable, Sendable {
  let text: String
  let opensWithLoneSurrogate: Bool

  init(_ text: String, opensWithLoneSurrogate: Bool = false) {
    self.text = text
    self.opensWithLoneSurrogate = opensWithLoneSurrogate
  }
}

private func excerptAround(_ body: String, index: Int, length: Int) -> String {
  let start = max(0, index - excerptRadius)
  let end = min(body.jsLength, index + length + excerptRadius)
  return (start > 0 ? "…" : "") + body.jsSlice(start, end) + (end < body.jsLength ? "…" : "")
}

private func withWriterNote(_ line: String, _ fact: DisclosureFact?) -> String {
  guard let note = fact?.writerNote?.jsTrim(), !note.isEmpty else { return line }
  return "\(line) — \(note)"
}

private func keyedLines(_ facts: [DisclosureFact]) -> String {
  facts.map { "- [\($0.factKey)] \($0.text)" }.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:175
func renderReaderKnows(_ facts: [DisclosureFact], pov: [PovMember]) -> String {
  let cast = pov.isEmpty ? "the point-of-view cast" : pov.map(\.name).joined(separator: ", ")
  let verb = pov.count > 1 ? "do not" : "does not"
  return facts.map { withWriterNote("- [\($0.factKey)] \($0.text) — the reader knows; \(cast) \(verb)", $0) }.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:182
func renderJudgeReaderKnows(_ facts: [DisclosureFact]) -> String {
  if facts.isEmpty { return "" }
  return
    "\n\n## THE READER KNOWS, THE POV CAST DOES NOT\n\(keyedLines(facts))\n\nThe prose may let the reader feel these; flag any POV character who acts on, states or relies on one in knowledgeCompliance."
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:269
func renderKnownFacts(_ facts: [DisclosureFact]) -> String {
  if facts.isEmpty { return "(none established — the POV cast starts this chapter with no ledgered facts)" }
  return keyedLines(facts)
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:275
func renderChapterReveals(_ facts: [DisclosureFact]) -> String {
  keyedLines(facts)
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:283
func renderHiddenConstraints(_ facts: [DisclosureFact]) -> String {
  withWriterNotes(facts).map { "- \($0.writerNote ?? "")" }.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:289
func withWriterNotes(_ facts: [DisclosureFact]) -> [DisclosureFact] {
  facts.filter { !($0.writerNote?.jsTrim().isEmpty ?? true) }
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:294
func renderForbiddenFacts(_ facts: [DisclosureFact]) -> String {
  keyedLines(facts)
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:312
func writerSafeLeakLines(prescan: [PrescanLeak], judgeIssues: [String], forbidden: [DisclosureFact]) -> [String] {
  writerSafeLeakLines(prescan: prescan, judgeIssues: judgeIssues.map { JudgeIssue($0) }, forbidden: forbidden)
}

func writerSafeLeakLines(prescan: [PrescanLeak], judgeIssues: [JudgeIssue], forbidden: [DisclosureFact]) -> [String] {
  let factByKey = forbidden.jsLastByKey(\.factKey)
  var lines = prescan.map { withWriterNote("remove or avoid \"\($0.term)\"", factByKey[JSString($0.factKey)]) }
  for issue in judgeIssues {
    let overConnection = !issue.opensWithLoneSurrogate && issue.text.jsTrimStart().jsToLowerCase().jsStartsWith(overConnectionMarker)
    let remedy = overConnection ? solvedClue : unknowableReveal
    let cited = forbidden.filter { issue.text.jsIncludes($0.factKey) }
    if cited.isEmpty { lines.append(remedy) }
    lines += cited.map { withWriterNote(remedy, $0) }
  }
  return lines.jsUnique().map { knowledgeLeakPrefix + $0 }
}

// apps/novel-forge-server/src/modules/bible/fact/knowledge-view.ts:328
func scanKnowledgeLeaks(_ body: String, hidden: [DisclosureFact]) throws(DisclosureError) -> [KnowledgeLeakIssue] {
  var issues: [KnowledgeLeakIssue] = []
  for fact in hidden {
    for term in fact.terms ?? [] {
      guard let match = try revealTermPattern(term)?.exec(body) else { continue }
      issues.append(KnowledgeLeakIssue(factKey: fact.factKey, term: term, excerpt: excerptAround(body, index: match.index, length: match.length)))
      break
    }
  }
  return issues
}
