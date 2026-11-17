// apps/novel-forge-server/src/modules/refinement/passage-rewrite.ts:10; `generating` has no native draft state before the phase 7 pipelines
enum RewriteDropReason: String, Sendable, Equatable {
  case noDraft = "no_draft"
  case locked
  case isolated
  case wholeChapter = "whole_chapter"
  case tooLong = "too_long"
  case notFound = "not_found"
  case ambiguous
  case unchanged

  // passage-rewrite.ts:42
  var why: String {
    switch self {
    case .noDraft: "the chapter has no draft"
    case .locked: "the chapter is final, so its prose changes only through Amend"
    case .isolated: "the chapter is isolated, so the chat cannot change its prose — edit it in the chapter editor"
    case .wholeChapter: "this reply already rewrites the whole chapter"
    case .tooLong: "the passage runs past \(maxPassageChars) characters"
    case .notFound: "its words are not in the chapter as it stands — select the passage and ask again"
    case .ambiguous: "its words occur more than once in the chapter — select the passage and ask again"
    case .unchanged: "it changed nothing"
    }
  }
}

enum RewriteResolution: Sendable, Equatable {
  case anchored(DraftRewritePassage)
  case dropped(RewriteDropReason)
}

/// A chapter's draft as a rewrite is anchored to it: `id` is `DraftIdentity`, `revision` the head's generation and `saveSeq` 0, because autosaves stay in this
/// device's working copy, which staging settles first. `locked` is the reference's `chapter <= storyCurrentChapter || status === 'final'`.
struct AnchorDraft: Sendable, Equatable {
  let id: String
  let revision: Int
  let saveSeq: Int
  let body: String
  let isolated: Bool
  let locked: Bool
}

enum PassageAnchoring {
  // passage-rewrite.ts:40
  private static let commentIndent = ProseRegex.literal(#"\n {3}"#, "g")

  // passage-rewrite.ts:62; a blank passage never validates, and would never end the reference's loop
  static func occurrences(_ body: String, _ passage: String) -> [PassageSpan] {
    let length = passage.jsLength
    guard length > 0 else { return [] }
    var spans = [PassageSpan]()
    var at = body.jsIndexOf(passage)
    while at != -1 {
      spans.append(PassageSpan(start: at, end: at + length))
      at = body.jsIndexOf(passage, at + 1)
    }
    return spans
  }

  private enum Located {
    case found(passage: String, span: PassageSpan)
    case dropped(RewriteDropReason)
  }

  // passage-rewrite.ts:94
  private static func locate(_ body: String, _ passage: String, hints: [PassageSpan]) -> Located {
    let unindented = passage.jsReplace(commentIndent, "\n")
    for candidate in unindented.jsEquals(passage) ? [passage] : [passage, unindented] {
      let spans = occurrences(body, candidate)
      if spans.isEmpty { continue }
      let told = spans.count == 1 ? spans : spans.filter { span in hints.contains { PassageRewrite.overlaps(span, $0) } }
      guard told.count == 1, let span = told.first else { return .dropped(.ambiguous) }
      return .found(passage: candidate, span: span)
    }
    return .dropped(.notFound)
  }

  // passage-rewrite.ts:104
  static func resolve(_ rewrite: DraftRewritePassage, draft: AnchorDraft?, hints: (AnchorDraft) -> [PassageSpan]) -> RewriteResolution {
    guard let draft else { return .dropped(.noDraft) }
    if draft.locked { return .dropped(.locked) }
    if draft.isolated { return .dropped(.isolated) }
    let passage = normalizeLineEndings(rewrite.passage)
    if passage.jsLength > maxPassageChars { return .dropped(.tooLong) }
    let located: String
    let span: PassageSpan
    switch locate(draft.body, passage, hints: hints(draft)) {
    case .dropped(let reason): return .dropped(reason)
    case .found(let passage, let found): (located, span) = (passage, found)
    }
    let replacement = fitReplacement(located, normalizeLineEndings(rewrite.replacement))
    if replacement.jsEquals(located) { return .dropped(.unchanged) }
    let leading = located.jsLength - located.jsTrimStart().jsLength
    let context = anchorContext(draft.body, start: span.start, end: span.end)
    let anchor = jsonRecord([
      ("draftId", .string(draft.id)), ("revision", .int(Int64(draft.revision))), ("saveSeq", .int(Int64(draft.saveSeq))), ("start", .int(Int64(span.start))),
      ("end", .int(Int64(span.end))), ("passageHash", .string(passageHash(located))),
      ("paragraph", .int(Int64(paragraphAt(draft.body, offset: span.start + leading)))), ("contextBefore", .string(context.contextBefore)),
      ("contextAfter", .string(context.contextAfter)),
    ])
    var resolved = rewrite
    resolved.passage = located
    resolved.replacement = replacement
    resolved.anchor = PassageRewriteAnchor(anchor)
    return resolved.anchor == nil ? .dropped(.notFound) : .anchored(resolved)
  }

  // passage-rewrite.ts:152
  static func wholeChapterEdits(_ ops: [ChangeOp]) -> Set<Int> {
    Set(
      ops.compactMap { op in
        switch op.operation {
        case .draftUpdate(let update): update.chapter
        case .draftRemove(let removal): removal.chapter
        default: nil
        }
      })
  }

  static func rewriteChapters(_ ops: [ChangeOp]) -> [Int] {
    Array(Set(ops.compactMap(\.passageRewrite).map(\.chapter))).sorted()
  }

  /// passage-rewrite.ts:176: a rewrite keeps the occurrence its anchor still finds, is anchored afresh when its passage occurs once, and is otherwise refused
  /// (RFN_004), never guessed; the first rewrite that cannot be placed names the refusal.
  static func stamp(_ ops: [ChangeOp], drafts: [Int: AnchorDraft]) throws(ProposalStagingError) -> [ChangeOp] {
    guard ops.contains(where: { $0.passageRewrite != nil }) else { return ops }
    let wholeChapter = wholeChapterEdits(ops)
    var stamped = [ChangeOp]()
    for op in ops {
      guard let rewrite = op.passageRewrite else {
        stamped.append(op)
        continue
      }
      if wholeChapter.contains(rewrite.chapter) { throw .rewriteNotPlaced(chapter: rewrite.chapter, reason: .wholeChapter) }
      let kept = { (draft: AnchorDraft) -> [PassageSpan] in PassageRewrite.locate(rewrite, in: draft.body, draftId: draft.id).map { [$0] } ?? [] }
      switch resolve(rewrite, draft: drafts[rewrite.chapter], hints: kept) {
      case .anchored(let resolved): stamped.append(ChangeOp(operation: .draftRewritePassage(resolved), metadata: op.metadata))
      case .dropped(let reason): throw .rewriteNotPlaced(chapter: rewrite.chapter, reason: reason)
      }
    }
    return stamped
  }

  // passage-rewrite.ts:207
  private static func rewrites(on ref: String, in ops: [ChangeOp]) -> [DraftRewritePassage]? {
    let touching = ops.filter { op in changeSetRefs([op]).contains { $0.jsEquals(ref) } }
    let rewrites = touching.compactMap(\.passageRewrite)
    return !touching.isEmpty && rewrites.count == touching.count ? rewrites : nil
  }

  /// passage-rewrite.ts:223: a newer card leaves an older one standing on the refs they share only when both rewrite those drafts passage by passage and every
  /// older passage still stands apart from every newer one in the draft as it stands.
  static func rewritesApart(older: [ChangeOp], newer: [ChangeOp], shared: [String], drafts: [Int: AnchorDraft]) -> Bool {
    shared.allSatisfy { ref in
      guard let olderRewrites = rewrites(on: ref, in: older), let newerRewrites = rewrites(on: ref, in: newer), let first = olderRewrites.first,
        let draft = drafts[first.chapter]
      else { return false }
      let olderSpans = olderRewrites.map { PassageRewrite.locate($0, in: draft.body, draftId: draft.id) }
      let newerSpans = newerRewrites.map { PassageRewrite.locate($0, in: draft.body, draftId: draft.id) }
      let placedOlder = olderSpans.compactMap { $0 }
      let placedNewer = newerSpans.compactMap { $0 }
      guard placedOlder.count == olderSpans.count, placedNewer.count == newerSpans.count else { return false }
      return placedOlder.allSatisfy { span in placedNewer.allSatisfy { !PassageRewrite.overlaps(span, $0) } }
    }
  }
}

extension ChangeOp {
  var passageRewrite: DraftRewritePassage? {
    guard case .draftRewritePassage(let rewrite) = operation else { return nil }
    return rewrite
  }
}
