// apps/novel-forge-server/src/modules/refinement/passage-rewrite.ts:13
struct DroppedRewrite: Sendable, Equatable {
  let chapter: Int
  let label: String?
  let reason: RewriteDropReason
}

// passage-rewrite.ts:19
struct AnchoredRewrites: Sendable, Equatable {
  let ops: [ChangeOp]
  let dropped: [DroppedRewrite]
}

enum TurnRewriteAnchoring {
  private struct Placement: Hashable {
    let chapter: Int
    let start: Int
    let end: Int
    let replacement: JSString
  }

  /// passage-rewrite.ts:139: each rewrite of a turn is anchored where its passage occurs once in its chapter, or once among the passage comments it answers;
  /// one that cannot be placed is left out with its reason, never guessed, and a second rewrite of the same words to the same text is dropped silently.
  static func anchor(_ ops: [ChangeOp], drafts: [Int: AnchorDraft], unreadable: Set<Int>, contexts: [ChatPassageContext]) -> AnchoredRewrites {
    guard ops.contains(where: { $0.passageRewrite != nil }) else { return AnchoredRewrites(ops: ops, dropped: []) }
    let wholeChapter = PassageAnchoring.wholeChapterEdits(ops)
    var kept = [ChangeOp]()
    var dropped = [DroppedRewrite]()
    var placed = Set<Placement>()
    for op in ops {
      guard let proposed = op.passageRewrite else {
        kept.append(op)
        continue
      }
      var rewrite = proposed
      rewrite.anchor = nil
      if !answersContext(proposed, contexts) { rewrite.contextIndex = nil }
      let chapter = proposed.chapter
      let resolution: RewriteResolution =
        if wholeChapter.contains(chapter) {
          .dropped(.wholeChapter)
        } else if unreadable.contains(chapter) {
          .dropped(.unreadable)
        } else {
          PassageAnchoring.resolve(rewrite, draft: drafts[chapter], hints: { commentSpans(rewrite, $0, contexts) })
        }
      switch resolution {
      case .dropped(let reason):
        dropped.append(DroppedRewrite(chapter: chapter, label: proposed.label.flatMap { $0.isEmpty ? nil : $0 }, reason: reason))
      case .anchored(let resolved):
        guard let anchor = resolved.anchor else { continue }
        let placement = Placement(chapter: chapter, start: anchor.start, end: anchor.end, replacement: JSString(resolved.replacement))
        if placed.insert(placement).inserted { kept.append(ChangeOp(operation: .draftRewritePassage(resolved), metadata: op.metadata)) }
      }
    }
    return AnchoredRewrites(ops: kept, dropped: dropped)
  }

  // passage-rewrite.ts:233
  static func droppedNote(_ dropped: [DroppedRewrite]) -> String? {
    guard !dropped.isEmpty else { return nil }
    let lines = dropped.map { entry in
      let subject = entry.label.map { "“\($0)” in chapter \(entry.chapter)" } ?? "A passage in chapter \(entry.chapter)"
      return "- \(subject): \(entry.reason.why)."
    }
    let count = dropped.count == 1 ? "a passage rewrite" : "\(dropped.count) passage rewrites"
    return (["Forge left out \(count):"] + lines).joined(separator: "\n")
  }

  // passage-rewrite.ts:154
  private static func answersContext(_ rewrite: DraftRewritePassage, _ contexts: [ChatPassageContext]) -> Bool {
    guard let position = rewrite.contextIndex.map({ $0 - 1 }), contexts.indices.contains(position) else { return false }
    return contexts[position].chapter == rewrite.chapter
  }

  // passage-rewrite.ts:82: the comment the rewrite answers, else every comment on its chapter, while they still describe the draft
  private static func commentSpans(_ rewrite: DraftRewritePassage, _ draft: AnchorDraft, _ contexts: [ChatPassageContext]) -> [PassageSpan] {
    let current = contexts.indices.filter { index in
      let context = contexts[index]
      return context.chapter == rewrite.chapter && context.draftId.jsEquals(draft.id) && context.revision == draft.revision && context.saveSeq == draft.saveSeq
    }
    let span = { (index: Int) in PassageSpan(start: contexts[index].start, end: contexts[index].end) }
    if let answered = rewrite.contextIndex.map({ $0 - 1 }), current.contains(answered) { return [span(answered)] }
    return current.map(span)
  }
}
