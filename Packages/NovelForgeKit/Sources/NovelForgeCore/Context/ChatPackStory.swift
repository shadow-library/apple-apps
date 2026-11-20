import ShadowText

// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
extension ChatPack {
  private enum Pattern {
    static let paragraphGap = ProseRegex.literal(#"\n\s*\n"#)
    static let whitespaceRun = ProseRegex.literal(#"\s+"#)
  }

  // novel-chat-context.ts:91
  private static func field(_ label: String, _ value: String?, maxTokens: Int = FieldCap.field) -> String? {
    guard let text = value?.jsTrim(), !text.isEmpty else { return nil }
    return "\(label): \(clipped(text, maxTokens: maxTokens))"
  }

  // novel-chat-context.ts:96
  static func renderStory(_ story: ChatPackStory) -> String {
    [
      field("Working title", story.title),
      field("Premise", story.premise ?? story.brief, maxTokens: FieldCap.premise),
      field("What it is about underneath", story.theme),
      field("Themes", story.themes.joined(separator: ", ")),
      field("What the reader is promised", story.readerPromise),
      field("Protagonist", story.protagonistKey),
      field("Opposition", story.opposition),
      field(endingQuestionPlannerOnlyLabel, story.endingQuestion),
      field(endingPlannerOnlyLabel, story.ending, maxTokens: FieldCap.ending) ?? "\(endingPlannerOnlyLabel): undecided for now",
      field("Author instructions", story.authorInstructions, maxTokens: FieldCap.instructions),
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
  }

  // novel-chat-context.ts:215
  static func notesParagraphs(_ notes: String) -> [String] {
    notes.jsSplit(Pattern.paragraphGap).map { $0.jsTrim() }.filter { !$0.isEmpty }
  }

  // novel-chat-context.ts:222
  static func renderNotesPointer(_ notes: String) -> String? {
    let paragraphs = notesParagraphs(notes)
    guard !paragraphs.isEmpty else { return nil }
    let words = paragraphs.reduce(0) { $0 + $1.jsSplit(Pattern.whitespaceRun).count }
    return
      "The author's own notes: \(paragraphs.count) paragraphs, about \(words) words. They are the author's words and outrank every summary; read them with get_notes before quoting, organising or critiquing them."
  }

  // novel-chat-context.ts:229
  private static let progressGroups: [(status: ChatPackProgressStatus, label: String)] = [
    (.answered, "Settled"), (.undecided, "Left undecided for now"), (.open, "Not settled yet"),
  ]

  // novel-chat-context.ts:236
  static func renderProgress(_ items: [ChatPackProgressLine]) -> String? {
    let lines = progressGroups.compactMap { group -> String? in
      let labels = items.filter { $0.status == group.status }.map(\.label)
      return labels.isEmpty ? nil : "- \(group.label): \(labels.joined(separator: ", "))"
    }
    guard !lines.isEmpty else { return nil }
    return
      "What the author has settled so far — reference only; never ask about an open item unless the author raises it or the chapter being planned needs it, and never a reason to refuse planning or writing:\n\(lines.joined(separator: "\n"))"
  }

  // novel-chat-context.ts:245
  private static func volumeStateLabel(_ state: VolumeState) -> String {
    switch state {
    case .notStarted: "not started"
    case .active: "active"
    case .goalMet: "goal met"
    }
  }

  // novel-chat-context.ts:248
  static func renderVolumeGoals(_ volumes: [ChatPackVolume]) -> String {
    let ordered = volumes.jsStableSorted { $0.ordinal < $1.ordinal }
    let current = ordered.first { $0.state == .active } ?? ordered.first { $0.state != .goalMet }
    return ordered.map { volume in
      let label = current.map { volume.ordinal > $0.ordinal } == true ? laterVolumeGoalLabel : "Goal"
      let objective = volume.objective?.jsTrim() ?? ""
      return
        "Vol \(volume.ordinal) \(volume.volumeKey) (\(volumeStateLabel(volume.state))) — \(volume.title ?? "untitled"). \(label): \(objective.isEmpty ? "not set yet" : objective)"
    }
    .joined(separator: "\n")
  }
}
