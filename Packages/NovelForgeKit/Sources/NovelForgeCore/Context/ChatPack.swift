import ShadowText

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
enum ChatPack {
  // novel-chat-context.ts:9
  static let requestBudget = 24_000
  // novel-chat-context.ts:10
  static let packFloor = 6_000
  // novel-chat-context.ts:11
  static let packMargin = 64
  // novel-chat-context.ts:13
  static let messageAllowance = 2_000

  // novel-chat-context.ts:15
  enum Cap {
    static let story = 3_000
    static let notebook = 2_500
    static let authorNotes = 200
    static let volumes = 1_000
    static let promises = 1_500
    static let inventory = 2_500
    static let chapterIndex = 1_500
    static let handoff = 3_500
    static let latestEnding = 700
    static let latestState = 800
    static let changedSince = 600
    static let progress = 500
  }

  // novel-chat-context.ts:30
  enum FieldCap {
    static let premise = 1_200
    static let field = 150
    static let ending = 300
    static let instructions = 400
  }

  // novel-chat-context.ts:31
  enum InventoryCap {
    static let entities = 800
    static let pages = 550
    static let facts = 450
    static let milestones = 200
  }

  // novel-chat-context.ts:32
  static let notebookLineShare = 3
  // novel-chat-context.ts:33
  static let chapterIndexCount = 40
  // novel-chat-context.ts:34
  static let leftOutNoteTokens = 24
  // pack-render.ts:12
  static let previousEndingTail = 500
  // pack-render.ts:19
  static let sizedSectionMargin = 32
  // pack-render.ts:16
  static let staleLabel = "[STALE — may not match the current plan]"
  // pack-render.ts:321
  static let draftLabel = "[DRAFT — not yet canon]\n"
  // isolation-read-policy.ts:16
  static let noBridgeSummary = "(unrestricted chapter — walled off, no approved bridge)"
  // isolation-read-policy.ts:18
  static let noApprovedBridge = "Walled off: an unrestricted chapter with no approved bridge for its current text, so nothing from it is available here."

  // novel-chat-context.ts:36
  static let plannerOnly = "PLANNER-ONLY — plan towards it, but never write it into a chapter plan before the one planned as the ending, a page the writer reads, or prose"
  // novel-chat-context.ts:37
  static let endingPlannerOnlyLabel = "Ending (\(plannerOnly))"
  // novel-chat-context.ts:38
  static let endingQuestionPlannerOnlyLabel = "Ending question (\(plannerOnly))"
  // novel-chat-context.ts:39
  static let laterVolumeGoalLabel = "Goal (PLANNER-ONLY — a later volume: keep it out of plans and pages for the chapters before it)"
}

extension ChatPack {
  // pack-render.ts:21
  static func makeSection(
    _ key: String, _ content: String, tier: ChatPackTier, sourceRefs: [String] = [], segment: ChatPackSegment = .volatile
  ) -> ChatPackSection {
    let rendered = renderSection(key, content)
    return ChatPackSection(key: key, tier: tier, segment: segment, tokens: countTokens(rendered), truncated: false, sourceRefs: sourceRefs, rendered: rendered)
  }

  // pack-render.ts:73
  static func fitToCap(_ section: ChatPackSection, cap: Int) -> ChatPackSection {
    guard section.tokens > cap else { return section }
    let split = section.rendered.jsIndexOf("\n\n")
    let heading = split == -1 ? "" : section.rendered.jsSlice(0, split + 2)
    let body = split == -1 ? section.rendered : section.rendered.jsSlice(split + 2)
    let room = max(0, cap - countTokens(heading) - sizedSectionMargin)
    var fitted = section
    fitted.rendered = heading + truncateAtParagraph(body, maxTokens: room).text
    fitted.tokens = countTokens(fitted.rendered)
    fitted.truncated = true
    return fitted
  }

  // context-assembler.service.ts:808
  static func capped(
    _ key: String, _ content: String, tier: ChatPackTier, cap: Int, segment: ChatPackSegment, required: Bool = false, priority: Int? = nil
  ) -> ChatPackSection {
    var section = fitToCap(makeSection(key, content, tier: tier, segment: segment), cap: cap)
    section.required = required
    section.priority = priority
    return section
  }

  // novel-chat-context.ts:86
  static func clipped(_ text: String, maxTokens: Int) -> String {
    let cut = truncateAtParagraph(text, maxTokens: maxTokens)
    return cut.truncated ? "\(cut.text) […]" : cut.text
  }

  // novel-chat-context.ts:357
  static func fitLines(_ lines: [String], maxTokens: Int, leftOut: String) -> String {
    var kept: [String] = []
    var used = 0
    for line in lines {
      let cost = countTokens(line) + 1
      if used + cost > maxTokens - leftOutNoteTokens { break }
      kept.append(line)
      used += cost
    }
    let omitted = lines.count - kept.count
    return omitted > 0 ? (kept + ["(+\(omitted) more \(leftOut))"]).joined(separator: "\n") : kept.joined(separator: "\n")
  }

  static func present(_ text: String?) -> String? {
    guard let text, !text.isEmpty else { return nil }
    return text
  }
}
