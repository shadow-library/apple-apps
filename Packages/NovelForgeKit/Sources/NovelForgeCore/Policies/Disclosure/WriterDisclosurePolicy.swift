// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:12
enum WriterField: String, CaseIterable, Sendable {
  case prose
  case summary
  case state
  case entity
  case reference
  case biblePage = "bible_page"
  case heading
  case plan
  case style
  case writerLine = "writer_line"
  case knowledge
  case note
  case plugin
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:14
struct WriterDisclosureInput: Equatable, Sendable {
  /// Nil is the planner's view, the reference's `Number.POSITIVE_INFINITY`: every reference resolves.
  var chapter: Int?
  var lockedFacts: [DisclosureFact]
  var plannerOnly: [String]
  var plannerPages: [String]
  var volumeOrdinals: [JSString: Int]
  var currentVolumeOrdinal: Int?
}

struct Withholding: Sendable {
  let pattern: JSRegex
  let weight: Int
  let copyFieldsOnly: Bool
  /// The weights the reference could have kept for this pattern; see `uniqueByPattern`.
  var possibleWeights: ClosedRange<Int>
  /// Nil when unknown: no body given, or one the pattern does not wrap.
  let reach: WithholdingReach?

  init(pattern: JSRegex, weight: Int, copyFieldsOnly: Bool, body: [BodyAtom]? = nil) {
    self.pattern = pattern
    self.weight = weight
    self.copyFieldsOnly = copyFieldsOnly
    possibleWeights = weight...weight
    reach = body.flatMap { WithholdingReach(pattern: pattern, body: $0) }
  }
}

struct WithheldCount: Equatable, Sendable {
  let field: WriterField
  var count: Int
}

/// Scrubs of one field where the order search gave up and withheld more than any order of the reference would.
struct FailedClosedCount: Equatable, Sendable {
  let field: WriterField
  /// Components withheld over every stretch their matches could reach.
  var components: Int
  /// Scrubs that withheld their whole text, a withholding of unknown reach having joined every other.
  var wholeTexts: Int
}

private enum PassageFloor {
  case truth
  case passage
  case sentence
}

private let copyFields: Set<WriterField> = [.biblePage, .entity, .reference, .plugin]
private let minTruthLength = 3
private let minPassageWords = 3
private let minPairLength = 12
private let minSentenceLength = 20
private let minUnspacedPassageLength = 6
private let minUnspacedSentenceLength = 12
private let leakNoteSeparator = " — "
private let notWordBefore = #"(?<![\p{L}\p{N}])"#
private let notWordAfter = #"(?![\p{L}\p{N}])"#
private let emphasisMark = "[*_]{0,2}"
private let wordGap = #"[*_]{0,2}\s+[*_]{0,2}"#
// The reference's call stack ends a writer note that quotes a finding leading back to itself; a chain this deep is refused as one.
private let maximumLeakNoteDepth = 64

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:51
private let unspacedScript = ProseRegex.literal(#"[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Thai}]"#, "u")
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:53
private let prescanLeak = ProseRegex.literal(#"^"(.+?)" exposes \[([^\]]+)\]"#)
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:54
private let sentenceBreak = ProseRegex.literal(#"(?<=[.!?。！？])\s+|\n+"#, "u")
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:55
private let listMarker = ProseRegex.literal(#"^\s*(?:[-*+>]|\d+[.)]|#{1,6})\s+"#)
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:56
private let trailingPunctuation = ProseRegex.literal(#"[\s.!?;:,…。！？]+$"#, "u")
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:57
private let emphasis = ProseRegex.literal(#"\*+|_{2,}|`"#, "g")
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:62
private let characterClasses: [(matches: JSRegex, pattern: String)] = [
  (ProseRegex.literal(#"["“”„«»]"#, "u"), #"["“”„«»]"#),
  (ProseRegex.literal(#"['’‘`]"#, "u"), #"['’‘`]"#),
  (ProseRegex.literal(#"[-‐‑–—]"#, "u"), #"[-‐‑–—]"#),
]

private func charPattern(_ char: String) -> String {
  characterClasses.first { $0.matches.test(char) }?.pattern ?? JSRegex.escape(char)
}

private func longEnough(_ text: String, _ floor: PassageFloor) -> Bool {
  if floor == .truth { return text.jsLength >= minTruthLength }
  if unspacedScript.test(text) { return text.jsLength >= (floor == .sentence ? minUnspacedSentenceLength : minUnspacedPassageLength) }
  let words = text.jsSplit(ProseRegex.whitespaceRun).count
  if words < 2 { return false }
  if floor == .sentence { return text.jsLength >= minSentenceLength }
  return words >= minPassageWords || text.jsLength >= minPairLength
}

private func escapedAtoms(_ text: String) -> [BodyAtom] {
  text.unicodeScalars.map { .character($0, source: JSRegex.escape(String($0))) }
}

private func compile(_ body: [BodyAtom], between before: String, and after: String, weight: Int, copyFieldsOnly: Bool = false) throws(DisclosureError) -> Withholding {
  do {
    let pattern = try JSRegex(before + body.map(\.source).joined() + after, flags: "giu")
    return Withholding(pattern: pattern, weight: weight, copyFieldsOnly: copyFieldsOnly, body: body)
  } catch {
    throw .pattern(error)
  }
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:82
private func passagePattern(_ text: String, _ floor: PassageFloor, copyFieldsOnly: Bool) throws(DisclosureError) -> Withholding? {
  let trimmed = text.jsReplace(listMarker, "").jsReplace(emphasis, "").jsReplace(trailingPunctuation, "").jsTrim()
  guard longEnough(trimmed, floor) else { return nil }
  let words = trimmed.jsSplit(ProseRegex.whitespaceRun).map { word in word.unicodeScalars.map { BodyAtom.character($0, source: charPattern(String($0))) } }
  let edge = BodyAtom.filler(source: emphasisMark, optional: true)
  let body = [edge] + words.joined(separator: [.filler(source: wordGap, optional: false)]) + [edge]
  return try compile(body, between: notWordBefore, and: notWordAfter, weight: trimmed.jsLength, copyFieldsOnly: copyFieldsOnly)
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:93
private func passageWithholdings(_ text: String?, _ floor: PassageFloor, copyFieldsOnly: Bool = false) throws(DisclosureError) -> [Withholding] {
  guard let text, !text.jsTrim().isEmpty else { return [] }
  var withholdings = [try passagePattern(text, floor, copyFieldsOnly: copyFieldsOnly)]
  for sentence in text.jsSplit(sentenceBreak) { withholdings.append(try passagePattern(sentence, .sentence, copyFieldsOnly: copyFieldsOnly)) }
  return withholdings.compactMap { $0 }
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:99
private func keyWithholding(_ key: String) throws(DisclosureError) -> Withholding {
  try compile(escapedAtoms(key), between: #"(?<![\p{L}\p{N}_])"#, and: #"(?![\p{L}\p{N}_])"#, weight: key.jsLength)
}

// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:104
private func factWithholdings(_ fact: DisclosureFact) throws(DisclosureError) -> [Withholding] {
  var withholdings = try passageWithholdings(fact.text, .truth) + passageWithholdings(fact.constraintNote, .passage)
  withholdings.append(try keyWithholding("fact:" + fact.factKey))
  if fact.factKey.jsIncludes("_") { withholdings.append(try keyWithholding(fact.factKey)) }
  for term in fact.terms ?? [] {
    if let pattern = try revealTermPattern(term, global: true) {
      withholdings.append(Withholding(pattern: pattern, weight: term.jsTrim().jsLength, copyFieldsOnly: false, body: escapedAtoms(term.jsTrim())))
    }
  }
  return withholdings
}

/// A repeated pattern keeps the first copy that applies to every field, else the last; which copy that is follows the order the reference read the facts, volumes and
/// pages in, so any weight among those copies is possible.
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:113
private func uniqueByPattern(_ withholdings: [Withholding]) -> [Withholding] {
  var order: [JSString] = []
  var copies: [JSString: [Withholding]] = [:]
  for withholding in withholdings {
    let id = JSString(withholding.pattern.source + "/" + withholding.pattern.flags)
    if copies[id] == nil { order.append(id) }
    copies[id, default: []].append(withholding)
  }
  let kept = order.compactMap { id -> Withholding? in
    guard let group = copies[id], var kept = group.first else { return nil }
    for copy in group.dropFirst() where kept.copyFieldsOnly { kept = copy }
    let candidates = group.contains { !$0.copyFieldsOnly } ? group.filter { !$0.copyFieldsOnly } : group
    kept.possibleWeights = (candidates.map(\.weight).min() ?? kept.weight)...(candidates.map(\.weight).max() ?? kept.weight)
    return kept
  }
  return kept.jsStableSorted { $0.weight > $1.weight }
}

/// The text of a finding after the prefix, by the reference's arithmetic: the prefix is found in the lowercased line and the original line is sliced at that offset.
private func leakFinding(_ line: String, prefixAt: Int) -> JudgeIssue {
  let start = prefixAt + knowledgeLeakPrefix.jsLength
  let units = line.jsCodeUnits
  let splitsPair = start > 0 && start < units.count && UTF16.isTrailSurrogate(units[start]) && UTF16.isLeadSurrogate(units[start - 1])
  guard splitsPair else { return JudgeIssue(line.jsSlice(start).jsTrim()) }
  return JudgeIssue(line.jsSlice(start + 1).jsTrimEnd(), opensWithLoneSurrogate: true)
}

/// A value: each copy keeps its own `withheld` counts.
// apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:133
struct WriterDisclosurePolicy: Sendable {
  let chapter: Int?
  let lockedFacts: [DisclosureFact]
  let withholdings: [Withholding]
  private let volumeOrdinals: [JSString: Int]
  private let currentVolumeOrdinal: Int?
  private(set) var withheld: [WithheldCount] = []
  private(set) var failedClosed: [FailedClosedCount] = []

  init(_ input: WriterDisclosureInput) throws(DisclosureError) {
    chapter = input.chapter
    lockedFacts = input.lockedFacts
    volumeOrdinals = input.volumeOrdinals
    currentVolumeOrdinal = input.currentVolumeOrdinal
    var all: [Withholding] = []
    for fact in input.lockedFacts { all += try factWithholdings(fact) }
    for text in input.plannerOnly { all += try passageWithholdings(text, .passage) }
    for text in input.plannerPages { all += try passageWithholdings(text, .passage, copyFieldsOnly: true) }
    withholdings = uniqueByPattern(all)
  }

  private init(planner: Void) {
    chapter = nil
    lockedFacts = []
    withholdings = []
    volumeOrdinals = [:]
    currentVolumeOrdinal = nil
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:154
  static let planner = WriterDisclosurePolicy(planner: ())

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:178
  mutating func scrub(_ text: String, _ field: WriterField) throws(DisclosureError) -> String {
    try scrub(text, field, depth: 0)
  }

  private mutating func scrub(_ text: String, _ field: WriterField, depth: Int) throws(DisclosureError) -> String {
    if text.isEmpty || withholdings.isEmpty { return text }
    guard depth < maximumLeakNoteDepth else { throw .leakFindingCycle }
    let (kept, safeLines) = try splitLeakFindings(text, depth: depth)
    let outcome = withholding(kept, field)
    if outcome.count > 0 {
      if let index = withheld.firstIndex(where: { $0.field == field }) {
        withheld[index].count += outcome.count
      } else {
        withheld.append(WithheldCount(field: field, count: outcome.count))
      }
    }
    if outcome.exhaustedComponents > 0 {
      let wholeTexts = outcome.exhaustedWholeText ? 1 : 0
      if let index = failedClosed.firstIndex(where: { $0.field == field }) {
        failedClosed[index].components += outcome.exhaustedComponents
        failedClosed[index].wholeTexts += wholeTexts
      } else {
        failedClosed.append(FailedClosedCount(field: field, components: outcome.exhaustedComponents, wholeTexts: wholeTexts))
      }
    }
    return safeLines.isEmpty ? outcome.text : ([outcome.text.jsTrim()] + safeLines).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  /// The withholdings that apply to `field`, over `text` as it stands (leak findings are not rewritten here).
  func withholding(_ text: String, _ field: WriterField) -> WithholdingOutcome {
    applyWithholdings(withholdings.filter { !$0.copyFieldsOnly || copyFields.contains(field) }, to: text)
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:195
  mutating func scrubSystemMessages(_ messages: [String]) throws(DisclosureError) -> [String] {
    var scrubbed: [String] = []
    for message in messages { scrubbed.append(try scrub(message, .plugin)) }
    return scrubbed
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:201
  mutating func scrubState(_ value: OrderedJSON, establishedFactsMax: Int) throws(DisclosureError) -> OrderedJSON {
    switch value {
    case .string(let text):
      return .string(try scrub(text, .state))
    case .array(let items):
      var scrubbed: [OrderedJSON] = []
      for item in items { scrubbed.append(try scrubState(item, establishedFactsMax: establishedFactsMax)) }
      return .array(scrubbed)
    case .object(let object):
      var pairs: [(key: String, value: OrderedJSON)] = []
      var taken = Set<JSString>()
      for entry in object.entries {
        let scrubbed = try scrub(entry.key, .state)
        var safeKey = scrubbed
        var suffix = 2
        while taken.contains(JSString(safeKey)) {
          safeKey = "\(scrubbed) (\(suffix))"
          suffix += 1
        }
        taken.insert(JSString(safeKey))
        if entry.key.jsEquals("establishedFacts"), case .array(let items) = entry.value {
          pairs.append((safeKey, .array(try establishedFacts(items, max: establishedFactsMax).map(OrderedJSON.string))))
        } else {
          pairs.append((safeKey, try scrubState(entry.value, establishedFactsMax: establishedFactsMax)))
        }
      }
      return .object(OrderedJSONObject(pairs))
    case .null, .bool, .int, .double:
      return value
    }
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:221
  func canResolve(_ ref: String) -> Bool {
    guard let chapter else { return true }
    let colon = ref.jsIndexOf(":")
    let (prefix, value) = colon == -1 ? ("", ref) : (ref.jsSlice(0, colon), ref.jsSlice(colon + 1))
    if prefix.jsEquals("volume") {
      guard let ordinal = volumeOrdinals[JSString(value)] else { return true }
      return currentVolumeOrdinal.map { ordinal <= $0 } ?? false
    }
    if prefix.jsEquals("chapter") {
      let number = JSNumber.from(value)
      return number.jsIsInteger && number < Double(chapter)
    }
    if prefix.jsEquals("bible_doc") {
      let slash = value.jsIndexOf("/")
      return !isWriterExcludedBibleDoc(BibleDocAddress(section: slash == -1 ? value : value.jsSlice(0, slash), slug: slash == -1 ? "" : value.jsSlice(slash + 1)))
    }
    return true
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:243
  func opensBy(_ openedChapter: Int?) -> Bool {
    guard let chapter, let openedChapter else { return true }
    return openedChapter <= chapter
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:252
  func allowedClues() throws(DisclosureError) -> [String] {
    var clues: [String] = []
    for fact in lockedFacts {
      for clue in fact.allowedClues ?? [] {
        if try cluesNamingTerms([clue], fact.terms).isEmpty { clues.append(clue) }
      }
    }
    return clues.map { $0.jsTrim() }.jsUnique().filter { !$0.isEmpty }
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:260
  mutating func leakLines(_ body: String) throws(DisclosureError) -> [String] {
    let leaks = try scanKnowledgeLeaks(body, hidden: lockedFacts).map { PrescanLeak(factKey: $0.factKey, term: $0.term) }
    return try safeLines(writerSafeLeakLines(prescan: leaks, judgeIssues: [JudgeIssue](), forbidden: lockedFacts), depth: 0)
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:269
  mutating func scrubLeakLine(_ line: String) throws(DisclosureError) -> String {
    try scrubLeakLine(line, depth: 0)
  }

  private mutating func scrubLeakLine(_ line: String, depth: Int) throws(DisclosureError) -> String {
    let at = line.jsIndexOf(leakNoteSeparator)
    if at == -1 { return line }
    let noteStart = at + leakNoteSeparator.jsLength
    return line.jsSlice(0, noteStart) + (try scrub(line.jsSlice(noteStart), .note, depth: depth))
  }

  private mutating func safeLines(_ lines: [String], depth: Int) throws(DisclosureError) -> [String] {
    var safe: [String] = []
    for line in lines { safe.append("- " + (try scrubLeakLine(line.jsSlice(knowledgeLeakPrefix.jsLength), depth: depth))) }
    return safe
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:277
  private mutating func establishedFacts(_ entries: [OrderedJSON], max: Int) throws(DisclosureError) -> [String] {
    var clean: [String] = []
    for entry in entries {
      if case .string(let text) = entry, try scanKnowledgeLeaks(text, hidden: lockedFacts).isEmpty { clean.append(text) }
    }
    var scrubbed: [String] = []
    for entry in clean.jsSlice(0, max) { scrubbed.append(try scrub(entry, .state)) }
    return scrubbed
  }

  // apps/novel-forge-server/src/modules/bible/fact/writer-disclosure-policy.ts:284
  private mutating func splitLeakFindings(_ text: String, depth: Int) throws(DisclosureError) -> (kept: String, safeLines: [String]) {
    guard text.jsToLowerCase().jsIncludes(knowledgeLeakPrefix) else { return (text, []) }
    var prescan: [PrescanLeak] = []
    var judgeIssues: [JudgeIssue] = []
    var kept: [String] = []
    for line in text.jsSplit("\n") {
      let at = line.jsToLowerCase().jsIndexOf(knowledgeLeakPrefix)
      if at == -1 {
        kept.append(line)
        continue
      }
      let finding = leakFinding(line, prefixAt: at)
      if !finding.opensWithLoneSurrogate, let match = prescanLeak.exec(finding.text), let term = match.groups.first ?? nil, let factKey = match.groups.dropFirst().first ?? nil,
        !term.isEmpty, !factKey.isEmpty
      {
        prescan.append(PrescanLeak(factKey: factKey, term: term))
      } else {
        judgeIssues.append(finding)
      }
    }
    let lines = writerSafeLeakLines(prescan: prescan, judgeIssues: judgeIssues, forbidden: lockedFacts)
    return (kept.joined(separator: "\n"), try safeLines(lines, depth: depth + 1))
  }
}
