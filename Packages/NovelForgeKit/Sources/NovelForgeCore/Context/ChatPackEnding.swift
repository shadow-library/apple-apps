// apps/novel-forge-server/src/modules/ai/context/pack-render.ts
extension ChatPack {
  // pack-render.ts:27
  static func makeSectionTail(_ key: String, _ content: String, maxTokens: Int, tier: ChatPackTier, sourceRefs: [String]) -> ChatPackSection {
    let cut = truncateAtParagraphTail(content, maxTokens: maxTokens)
    let rendered = renderSection(key, cut.text)
    return ChatPackSection(key: key, tier: tier, segment: .volatile, tokens: countTokens(rendered), truncated: cut.truncated, sourceRefs: sourceRefs, rendered: rendered)
  }

  // pack-render.ts:282
  private static func scrubbedTail(_ prose: String, disclosure: WriterDisclosurePolicy) throws(DisclosureError) -> String {
    var policy = disclosure
    return try policy.scrub(truncateAtParagraphTail(prose, maxTokens: previousEndingTail * 2).text, .prose)
  }

  /// How a chapter ends as the next chapter's planner reads it, within `cap`. An isolated chapter reads as walled off, as the vault has no approved bridges, and the
  /// continuation state is left out as the vault records none.
  // pack-render.ts:348
  static func previousEnding(
    chapter: Int, row: ChatPackEndingRow?, draft: ChatPackEndingDraft?, disclosure: WriterDisclosurePolicy = .planner, cap: Int = Cap.latestEnding
  ) throws(DisclosureError) -> ChatPackSection? {
    let refs = ["chapter:\(chapter)"]
    let stale = draft?.staleReason != nil ? "\(staleLabel)\n" : ""
    let found: ChatPackSection?
    if let row {
      if row.isolated {
        found = makeSection("prev_ending", noApprovedBridge, tier: .canonical, sourceRefs: refs)
      } else {
        found = makeSectionTail(
          "prev_ending", try scrubbedTail(row.content ?? "", disclosure: disclosure), maxTokens: previousEndingTail, tier: .canonical, sourceRefs: refs)
      }
    } else if let draft, draft.isolated {
      found = makeSection("prev_ending", "\(draftLabel)\(stale)\(noApprovedBridge)", tier: .working, sourceRefs: refs)
    } else if let body = present(draft?.body) {
      let cut = truncateAtParagraphTail(try scrubbedTail(body, disclosure: disclosure), maxTokens: previousEndingTail)
      let rendered = renderSection("prev_ending", "\(draftLabel)\(stale)\(cut.text)")
      found = ChatPackSection(
        key: "prev_ending", tier: .working, segment: .volatile, tokens: countTokens(rendered), truncated: cut.truncated, sourceRefs: refs, rendered: rendered)
    } else {
      found = nil
    }
    return found.map { fitToCap($0, cap: cap) }
  }
}
