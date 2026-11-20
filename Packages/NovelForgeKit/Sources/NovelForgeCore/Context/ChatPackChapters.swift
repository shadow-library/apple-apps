import ShadowText

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
extension ChatPackChapter {
  /// An isolated chapter as a standard call reads it, with no approved bridge: its title withheld and its summary a walled-off note.
  // apps/novel-forge-server/src/modules/ai/context/pack-render.ts:254
  var walledOff: ChatPackChapter {
    guard isolated else { return self }
    var walled = self
    walled.title = nil
    walled.summary = ChatPack.noBridgeSummary
    return walled
  }
}

extension ChatPackDraft {
  // apps/novel-forge-server/src/modules/ai/context/pack-render.ts:254
  var walledOff: ChatPackDraft {
    guard isolated else { return self }
    var walled = self
    walled.title = nil
    walled.summary = ChatPack.noBridgeSummary
    return walled
  }
}

extension ChatPack {
  private enum Standing: String {
    case final
    case approved
    case readyToRead = "ready to read"
    case changed = "changed — needs a look"
    case beingWritten = "being written"
  }

  private struct IndexedChapter {
    var number: Int
    var title: String?
    var standing: Standing
    var isolated: Bool
    var summary: String?
  }

  // novel-chat-context.ts:414
  private static func standing(of review: DraftReviewState) -> Standing {
    switch review {
    case .generating: .beingWritten
    case .needsReview: .readyToRead
    case .contradiction: .changed
    case .approved: .approved
    case .final: .final
    }
  }

  // novel-chat-context.ts:430
  private static func indexChapters(_ chapters: [ChatPackChapter], _ drafts: [ChatPackDraft]) -> [IndexedChapter] {
    var byNumber: [Int: IndexedChapter] = [:]
    for draft in drafts {
      byNumber[draft.chapter] = IndexedChapter(
        number: draft.chapter, title: draft.title, standing: standing(of: draft.review), isolated: draft.isolated, summary: draft.summary)
    }
    for chapter in chapters {
      let draft = byNumber[chapter.number]
      byNumber[chapter.number] = IndexedChapter(
        number: chapter.number, title: chapter.title ?? draft?.title, standing: .final, isolated: chapter.isolated,
        summary: present(chapter.summary) ?? present(draft?.summary))
    }
    return byNumber.values.sorted { $0.number < $1.number }
  }

  /// A final import counts as written.
  // novel-chat-context.ts:450
  static func nextChapterNumber(chapters: [ChatPackChapter], drafts: [ChatPackDraft]) -> Int {
    nextWritableChapter(draftChapters: drafts.map(\.chapter), finalizedChapters: chapters.map(\.number))
  }

  // novel-chat-context.ts:455
  static func renderChapterIndex(chapters: [ChatPackChapter], drafts: [ChatPackDraft], plannedChapters: [Int]) -> String? {
    let indexed = indexChapters(chapters, drafts)
    if indexed.isEmpty && plannedChapters.isEmpty { return nil }
    func count(_ standing: Standing) -> Int { indexed.count { $0.standing == standing } }
    let written = Set(indexed.map(\.number))
    let planned = plannedChapters.count { !written.contains($0) }
    let counts =
      "\(indexed.count) chapters written: \(count(.final)) final, \(count(.approved)) approved, \(count(.readyToRead)) ready to read; \(planned) planned but not written."
    let shown = Array(indexed.suffix(chapterIndexCount))
    let earlier = indexed.count - shown.count
    let lines = shown.map { "\($0.number) — \($0.title ?? "Chapter \($0.number)") [\($0.standing.rawValue)\($0.isolated ? ", unrestricted" : "")]" }
    let leftOut = earlier > 0 ? ["(\(earlier) earlier chapters left out — get_chapter_summaries reads them)"] : []
    return ([counts] + leftOut + lines).joined(separator: "\n")
  }

  // novel-chat-context.ts:469
  private static func renderEndingContract(_ contract: ChatPackEndingContract?) -> String? {
    guard let contract else { return nil }
    let parts = [
      contract.hookType.map { "hook: \($0)" },
      contract.emotionalBeat.map { "feeling: \($0)" },
      contract.openQuestion.map { "leaves open: \($0)" },
      contract.handoffState.map { "hands off: \($0)" },
    ]
    .compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "; ")
  }

  // novel-chat-context.ts:481
  private static func planLine(_ label: String, _ value: String?) -> String? {
    guard let text = value?.jsTrim(), !text.isEmpty else { return nil }
    return "\(label): \(text)"
  }

  // novel-chat-context.ts:486
  private static func renderPlan(_ brief: ChatPackBrief) -> String {
    let scenes = brief.scenes.enumerated().map { "  \($0.offset + 1). \($0.element.summary)\(present($0.element.pov).map { " (POV \($0))" } ?? "")" }
    return [
      "Plan for chapter \(brief.chapter) (rev \(brief.revision)\(brief.writeMode == .external ? ", the author writes it" : "")): \(brief.title ?? "untitled")",
      planLine("What it does", brief.chapterPurpose),
      planLine("Agreed direction", brief.direction),
      planLine("POV", brief.pov),
      brief.body.jsTrim(),
      scenes.isEmpty ? nil : "Scenes:\n\(scenes.joined(separator: "\n"))",
      planLine("Ends on", renderEndingContract(brief.endingContract)),
      brief.claimedMilestones.isEmpty ? nil : "This chapter reaches: \(brief.claimedMilestones.joined(separator: ", "))",
      planLine("Content for this chapter", brief.contentMode),
      brief.isEnding ? "This is the chapter planned as the ending." : nil,
      planLine("Author guidance", brief.guidance),
    ]
    .compactMap(present)
    .joined(separator: "\n")
  }

  // novel-chat-context.ts:506
  private static func nextStatus(_ next: Int, _ brief: ChatPackBrief?) -> String {
    guard let brief else { return "Next chapter: \(next) — no plan yet." }
    if let reason = present(brief.staleReason) { return "Next chapter: \(next) — its plan is stale (\(reason)); replan or confirm it before writing." }
    return "Next chapter: \(next) — planned, not written yet."
  }

  // novel-chat-context.ts:512
  static func renderHandoff(chapters: [ChatPackChapter], drafts: [ChatPackDraft], briefs: [ChatPackBrief]) -> String {
    let next = nextChapterNumber(chapters: chapters, drafts: drafts)
    let latest = indexChapters(chapters, drafts).last { $0.number < next }
    func briefFor(_ chapter: Int) -> ChatPackBrief? { briefs.first { $0.chapter == chapter } }
    let latestLines: [String?] =
      latest.map { latest in
        [
          "Latest chapter: \(latest.number) — \(latest.title ?? "untitled") [\(latest.standing.rawValue)]",
          present(latest.summary).map { "AI summary of chapter \(latest.number) (the author's words above outrank it): \($0.jsTrim())" },
          planLine("It ends on", renderEndingContract(briefFor(latest.number)?.endingContract)),
        ]
      } ?? ["Nothing is written yet."]
    let nextBrief = briefFor(next)
    return (latestLines + [nextStatus(next, nextBrief), nextBrief.map(renderPlan)]).compactMap(present).joined(separator: "\n")
  }

  // novel-chat-context.ts:539
  static func renderAwaitingAuthor(_ awaiting: ChatPackAwaitingAuthor) -> String? {
    let continuity = awaiting.continuity.sorted()
    let parts: [String?] =
      [
        continuity.isEmpty
          ? nil
          : "Story Bible additions for chapter\(continuity.count == 1 ? "" : "s") \(continuity.map(String.init).joined(separator: ", ")) (action.apply_continuity)"
      ]
      + awaiting.asking.jsStableSorted { $0.chapter < $1.chapter }.map {
        "chapter \($0.chapter)'s finalize review, \($0.open) answer\($0.open == 1 ? "" : "s") open on its Story Bible card"
      }
      + awaiting.answered.sorted().map { "chapter \($0)'s finalize review, answered (action.finalize)" }
    let waiting = parts.compactMap { $0 }
    return waiting.isEmpty ? nil : "Waiting on the author: \(waiting.joined(separator: "; "))"
  }

  /// Jobs are left out: the vault has none.
  // context-assembler.service.ts:868
  static func renderPipelineStatus(_ pipeline: ChatPackPipeline) -> String {
    var lines = ["Story cursor (last finalized chapter): \(pipeline.storyCurrentChapter)"]
    if pipeline.drafts.isEmpty {
      lines.append("Drafts: none yet")
    } else {
      var order: [DraftReviewState] = []
      var byReview: [DraftReviewState: [Int]] = [:]
      for draft in pipeline.drafts {
        if byReview[draft.review] == nil { order.append(draft.review) }
        byReview[draft.review, default: []].append(draft.chapter)
      }
      lines.append("Drafts: \(order.map { "\($0.rawValue) [\((byReview[$0] ?? []).map(String.init).joined(separator: ", "))]" }.joined(separator: "; "))")
    }
    if !pipeline.staleBriefChapters.isEmpty { lines.append("Stale briefs: chapters \(pipeline.staleBriefChapters.map(String.init).joined(separator: ", "))") }
    if pipeline.pendingProposals > 0 { lines.append("Pending proposals awaiting review: \(pipeline.pendingProposals)") }
    if let awaiting = renderAwaitingAuthor(pipeline.awaiting) { lines.append(awaiting) }
    return lines.joined(separator: "\n")
  }

  // context-assembler.service.ts:924
  static func changedSinceLines(_ changes: ChatPackChanges) -> [String] {
    changes.volumes.map { volume in volume.revision.map { "volume:\(volume.volumeKey) is now at revision \($0)" } ?? "volume:\(volume.volumeKey) has changed" }
      + changes.briefs.map { "chapter:\($0.chapter) brief is now at revision \($0.revision)" }
      + changes.docs.map { "doc:\($0.section)/\($0.slug) is now at revision \($0.revision)" }
  }
}
