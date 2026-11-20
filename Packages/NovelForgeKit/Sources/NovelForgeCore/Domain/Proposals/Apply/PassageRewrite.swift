import ShadowText

// apps/novel-forge-server/src/modules/refinement/passage-rewrite.ts
enum PassageRewrite {
  // passage-rewrite.ts:58
  static func overlaps(_ first: PassageSpan, _ second: PassageSpan) -> Bool {
    first.start < second.end && second.start < first.end
  }

  /// passage-rewrite.ts:69: where a staged passage stands in `body`, or nil when it has no anchor, its draft was replaced, or it is gone, edited or ambiguous.
  static func locate(_ rewrite: DraftRewritePassage, in body: String, draftId: String) -> PassageSpan? {
    guard let anchor = rewrite.anchor, anchor.draftId.jsEquals(draftId) else { return nil }
    let passage = PassageAnchor(
      start: anchor.start, end: anchor.end, passageHash: anchor.passageHash, passage: rewrite.passage, contextBefore: anchor.contextBefore,
      contextAfter: anchor.contextAfter)
    switch locatePassage(body, anchor: passage) {
    case .fresh(let start, let end), .relocated(let start, let end): return PassageSpan(start: start, end: end)
    case .stale: return nil
    }
  }

  // passage-rewrite.ts:76
  static func staleRefusal(_ rewrite: DraftRewritePassage, chapter: Int) -> ApplyRefusal {
    let label = rewrite.label?.jsTrim() ?? ""
    let passage =
      if !label.isEmpty { "“\(label)”" } else if let anchor = rewrite.anchor { "¶\(anchor.paragraph)" } else { "a passage" }
    return .stale(passage: passage, chapter: chapter)
  }

  /// passage-rewrite.ts:190: the body with every rewrite in place, written from the end back; refused whole, naming the first rewrite that no longer
  /// stands (RFN_021), or for two rewrites of the same words (RFN_020).
  static func rewrittenBody(_ body: String, draftId: String, chapter: Int, _ rewrites: [DraftRewritePassage]) throws(ApplyRefusal) -> String {
    var located = [(order: Int, span: PassageSpan, replacement: String)]()
    for (order, rewrite) in rewrites.enumerated() {
      guard let span = locate(rewrite, in: body, draftId: draftId) else { throw staleRefusal(rewrite, chapter: chapter) }
      located.append((order, span, rewrite.replacement))
    }
    located.sort { $0.span.start != $1.span.start ? $0.span.start > $1.span.start : $0.order < $1.order }
    for (later, earlier) in zip(located, located.dropFirst()) where overlaps(earlier.span, later.span) { throw .overlapping(chapter: chapter) }
    return located.reduce(body) { text, rewrite in replacePassage(text, start: rewrite.span.start, end: rewrite.span.end, replacement: rewrite.replacement) }
  }
}
