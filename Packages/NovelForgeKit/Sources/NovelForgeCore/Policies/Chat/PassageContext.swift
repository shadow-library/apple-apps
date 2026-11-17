// apps/novel-forge-server/src/modules/refinement/passage-context.ts:10
let maxPassageContexts = 10

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:11
let maxPassageQuoteChars = 2000

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:12
let maxPassageCommentChars = 2000

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:13
let passageCommentsHeading = "Passage comments:"

private let maxSafeInteger: UInt = 9_007_199_254_740_991

/// Offsets are UTF-16 code units into the draft body as the author read it, at `revision`.
// apps/novel-forge-server/src/modules/refinement/passage-context.ts:16
struct PassageContextInput: Equatable, Sendable {
  var chapter: Int
  var draftId: String
  var revision: Int
  var saveSeq: Int?
  var start: Int
  var end: Int
  var passageHash: String
  var quote: String
  var comment: String
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:75
struct ChatPassageContext: Equatable, Sendable {
  var chapter: Int
  var draftId: String
  var revision: Int
  var saveSeq: Int
  var start: Int
  var end: Int
  var passageHash: String
  var quote: String
  var comment: String
  var firstParagraph: Int
  var lastParagraph: Int
}

struct PassageSpan: Equatable, Sendable {
  var start: Int
  var end: Int
}

struct PassageDraft: Equatable, Sendable {
  var id: String
  var chapter: Int
  var revision: Int
  var saveSeq: Int
  var body: String
  var isolated: Bool
}

enum PassageContextError: Error, Equatable, Sendable {
  case changed(chapter: Int)
  case mismatched(chapter: Int)
  case isolated(chapter: Int)

  var code: String {
    switch self {
    case .changed: "CHT_009"
    case .mismatched: "CHT_010"
    case .isolated: "CHT_011"
    }
  }

  var chapter: Int {
    switch self {
    case .changed(let chapter), .mismatched(let chapter), .isolated(let chapter): chapter
    }
  }
}

private func uniqueSpan(_ body: String, _ quote: String) -> PassageSpan? {
  let found = body.jsIndexOf(quote)
  guard found != -1, body.jsIndexOf(quote, found + 1) == -1 else { return nil }
  return PassageSpan(start: found, end: found + quote.jsLength)
}

private func sliceEquals(_ body: String, _ input: PassageContextInput) -> Bool {
  body.jsSliceCodeUnits(input.start, input.end) == input.quote.jsCodeUnits
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:45
func relocateQuote(_ body: String, input: PassageContextInput, earlierBody: String?) -> PassageSpan? {
  guard let earlierBody, sliceEquals(earlierBody, input) else { return uniqueSpan(body, input.quote) }
  let context = anchorContext(earlierBody, start: input.start, end: input.end)
  let anchor = PassageAnchor(
    start: input.start, end: input.end, passageHash: input.passageHash, passage: input.quote, contextBefore: context.contextBefore, contextAfter: context.contextAfter)
  switch locatePassage(body, anchor: anchor) {
  case .fresh(let start, let end), .relocated(let start, let end): return PassageSpan(start: start, end: end)
  case .stale: return nil
  }
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:53
private func isWellFormed(_ input: PassageContextInput) -> Bool {
  guard input.start.magnitude <= maxSafeInteger, input.end.magnitude <= maxSafeInteger else { return false }
  return input.quote.jsTrim().jsLength > 0 && input.end - input.start == input.quote.jsLength && passageHash(input.quote).jsEquals(input.passageHash)
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:69
private func anchored(_ draft: PassageDraft, _ input: PassageContextInput, earlierBody: () -> String?) throws(PassageContextError) -> ChatPassageContext {
  let inPlace = sliceEquals(draft.body, input)
  let located = inPlace ? PassageSpan(start: input.start, end: input.end) : relocateQuote(draft.body, input: input, earlierBody: earlierBody())
  guard let span = located else { throw .changed(chapter: input.chapter) }
  let leading = input.quote.jsLength - input.quote.jsTrimStart().jsLength
  let trailing = input.quote.jsLength - input.quote.jsTrimEnd().jsLength
  return ChatPassageContext(
    chapter: draft.chapter,
    draftId: draft.id,
    revision: draft.revision,
    saveSeq: draft.saveSeq,
    start: span.start,
    end: span.end,
    passageHash: input.passageHash,
    quote: input.quote,
    comment: input.comment.jsTrim(),
    firstParagraph: paragraphAt(draft.body, offset: span.start + leading),
    lastParagraph: paragraphAt(draft.body, offset: span.end - trailing - 1)
  )
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:60
private func earlierBody(_ draft: PassageDraft, _ input: PassageContextInput, snapshot: (_ draftId: String, _ revision: Int) -> String?) -> String? {
  guard input.revision < draft.revision else { return nil }
  return snapshot(draft.id, input.revision)
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:92
func resolvePassageContexts(
  _ inputs: [PassageContextInput], drafts: [PassageDraft], snapshot: (_ draftId: String, _ revision: Int) -> String?
) throws(PassageContextError) -> [ChatPassageContext] {
  for input in inputs where !isWellFormed(input) { throw .mismatched(chapter: input.chapter) }
  var resolved: [ChatPassageContext] = []
  for input in inputs {
    guard let draft = drafts.first(where: { $0.chapter == input.chapter }), draft.id.jsEquals(input.draftId) else { throw .changed(chapter: input.chapter) }
    if draft.isolated { throw .isolated(chapter: input.chapter) }
    resolved.append(try anchored(draft, input, earlierBody: { earlierBody(draft, input, snapshot: snapshot) }))
  }
  return resolved
}

private func indented(_ text: String) -> String {
  text.jsSplit("\n").joined(separator: "\n   ")
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:112
private func renderPassageContext(_ context: ChatPassageContext, _ index: Int) -> String {
  let paragraphs = context.firstParagraph == context.lastParagraph ? "¶\(context.firstParagraph)" : "¶\(context.firstParagraph)–\(context.lastParagraph)"
  return [
    "\(index + 1). Chapter \(context.chapter), revision \(context.revision), \(paragraphs) (chars \(context.start)–\(context.end))",
    "   Quote: \"\(indented(context.quote))\"",
    "   Comment: \(context.comment.isEmpty ? "(none)" : indented(context.comment))",
  ].joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:122
func renderTurnContent(_ content: String, contexts: [ChatPassageContext]?) -> String {
  guard let contexts, !contexts.isEmpty else { return content }
  let block = ([passageCommentsHeading] + contexts.enumerated().map { renderPassageContext($1, $0) }).joined(separator: "\n")
  return content.jsTrim().isEmpty ? block : "\(content)\n\n\(block)"
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:129
func authorWords(_ content: String, contexts: [ChatPassageContext]?) -> String {
  ([content] + (contexts ?? []).map(\.comment)).filter { !$0.jsTrim().isEmpty }.joined(separator: "\n\n")
}

// apps/novel-forge-server/src/modules/refinement/passage-context.ts:134
func turnScreens(_ content: String, contexts: [ChatPassageContext]?) -> [ScreenedText] {
  [ScreenedText(text: content, scope: .supplied, source: "Your message")]
    + (contexts ?? []).flatMap { context in
      [
        ScreenedText(text: context.quote, scope: .supplied, source: "The passage you quoted from chapter \(context.chapter)"),
        ScreenedText(text: context.comment, scope: .supplied, source: "Your comment on chapter \(context.chapter)"),
      ]
    }
}
