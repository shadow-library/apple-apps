import ShadowText

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:4
struct BibleDocAddress: Sendable, Hashable {
  let section: String
  let slug: String

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:62
  static let organisedTimeline = BibleDocAddress(section: "project", slug: "timeline")

  // apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:63
  static let openQuestions = BibleDocAddress(section: "project", slug: "open-questions")

  static func == (left: BibleDocAddress, right: BibleDocAddress) -> Bool {
    left.section.jsEquals(right.section) && left.slug.jsEquals(right.slug)
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(JSString(section))
    hasher.combine(JSString(slug))
  }
}

struct BibleDocAccess: Sendable, Equatable {
  let writerExcluded: Bool
  let plannerOnly: Bool
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:71
private let plannerOnlyDocs = [BibleDocAddress.organisedTimeline, .openQuestions]

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:77
private let writerExcludedDocs = [
  BibleDocAddress(section: "story_state", slug: "volume-plan"), BibleDocAddress(section: "story_state", slug: "volumes"), BibleDocAddress(section: "plot", slug: "escalation-map"),
]

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:87
func isPlannerOnlyBibleDoc(_ doc: BibleDocAddress) -> Bool {
  plannerOnlyDocs.contains(doc)
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:91
func isWriterExcludedBibleDoc(_ doc: BibleDocAddress) -> Bool {
  isPlannerOnlyBibleDoc(doc) || writerExcludedDocs.contains(doc)
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:96
func bibleDocAccess(_ doc: BibleDocAddress) -> BibleDocAccess {
  BibleDocAccess(writerExcluded: isWriterExcludedBibleDoc(doc), plannerOnly: isPlannerOnlyBibleDoc(doc))
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:57
func bibleDocExcerpt(body: String?, maxChars: Int) -> String {
  let firstParagraph = bibleDocPlainText(body ?? "").jsSplit(BibleDocPattern.paragraphBreak, limit: 1).first ?? ""
  return clipAtBoundary(firstParagraph, maxChars: maxChars)
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:34
func bibleDocPlainText(_ markdown: String) -> String {
  markdown.jsSplit("\n")
    .filter { !BibleDocPattern.headingLine.test($0) }
    .map { $0.jsReplace(BibleDocPattern.listMarker, "").jsReplace(BibleDocPattern.quoteMarker, "") }
    .joined(separator: "\n")
    .jsReplace(BibleDocPattern.link, "$1")
    .jsReplace(BibleDocPattern.inlineMarks, "")
    .jsTrim()
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:15
func clipAtBoundary(_ text: String, maxChars: Int) -> String {
  let flat = text.jsReplace(BibleDocPattern.whitespaceRuns, " ").jsTrim()
  guard flat.jsLength > maxChars else { return flat }
  let window = flat.jsSlice(0, maxChars + 1)
  var sentenceEnd = -1
  for match in window.jsMatchAll(BibleDocPattern.sentenceEnd) where match.endIndex <= maxChars { sentenceEnd = match.endIndex }
  if Double(sentenceEnd) >= Double(maxChars) / 2 { return flat.jsSlice(0, sentenceEnd) }
  let units = window.jsCodeUnits
  let wordBreak = ([0x20] + clauseBreaks).map { units.lastIndex(of: $0) ?? -1 }.max() ?? -1
  if wordBreak > 0 { return flat.jsSlice(0, wordBreak).jsReplace(BibleDocPattern.trailingBreaks, "") + "…" }
  if sentenceEnd > 0 { return flat.jsSlice(0, sentenceEnd) }
  return flat.jsSlice(0, maxChars) + "…"
}

// apps/novel-forge-server/src/modules/ai/context/bible-docs.ts:11 '，、；：'
private let clauseBreaks: [UInt16] = [0xFF0C, 0x3001, 0xFF1B, 0xFF1A]

private enum BibleDocPattern {
  static let sentenceEnd = ProseRegex.literal(#"[.!?]["'”’)\]]?(?=\s|$)|[。！？]["'”’）」』]?"#, "g")
  static let whitespaceRuns = ProseRegex.literal(#"\s+"#, "g")
  static let trailingBreaks = ProseRegex.literal(#"[\s,;:—–-]+$"#)
  static let headingLine = ProseRegex.literal(#"^\s*#{1,6}\s"#)
  static let listMarker = ProseRegex.literal(#"^\s*(?:[-*+]|\d+[.)])\s+"#)
  static let quoteMarker = ProseRegex.literal(#"^\s*>\s?"#)
  static let link = ProseRegex.literal(#"\[([^\]]*)\]\([^)]*\)"#, "g")
  static let inlineMarks = ProseRegex.literal(#"(\*\*|__|\*|`)"#, "g")
  static let paragraphBreak = ProseRegex.literal(#"\n\s*\n"#)
}
