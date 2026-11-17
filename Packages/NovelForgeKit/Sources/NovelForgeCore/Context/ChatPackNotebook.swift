// apps/novel-forge-server/src/modules/ai/context/novel-chat-context.ts
extension ChatPack {
  private struct LineGroup {
    var heading: String
    var lines: [String]
  }

  private static let turnedDownLimit = 10
  private static let turnedDownChars = 160

  private enum Pattern {
    static let whitespaceRun = ProseRegex.literal(#"\s+"#, "g")
  }

  // novel-chat-context.ts:123
  private static func fitGroups(_ groups: [LineGroup], maxTokens: Int, leftOut: String) -> String {
    var used = leftOutNoteTokens
    var omitted = 0
    let lineCap = Int((Double(maxTokens) / Double(notebookLineShare)).rounded(.down))
    var rendered: [String] = []
    for unclipped in groups {
      let lines = unclipped.lines.map { clipped($0, maxTokens: lineCap) }
      var kept = Set<Int>()
      let headingCost = countTokens(unclipped.heading) + 2
      for index in lines.indices.reversed() {
        let cost = countTokens(lines[index]) + 1 + (kept.isEmpty ? headingCost : 0)
        if used + cost > maxTokens {
          omitted += 1
          continue
        }
        kept.insert(index)
        used += cost
      }
      if !kept.isEmpty { rendered.append(([unclipped.heading] + lines.indices.filter(kept.contains).map { lines[$0] }).joined(separator: "\n")) }
    }
    if omitted > 0 { rendered.append("(+\(omitted) more \(leftOut))") }
    return rendered.joined(separator: "\n\n")
  }

  // novel-chat-context.ts:147
  private static func isDecidedKind(_ kind: LedgerEntryKind) -> Bool {
    kind == .decision || kind == .system
  }

  // novel-chat-context.ts:157
  private static func isTurnedDownIdea(_ entry: ChatPackLedgerEntry) -> Bool {
    entry.kind == .rejected && present(entry.ideaId) != nil && entry.rejectionScope != nil
  }

  // novel-chat-context.ts:151
  private static func turnedDownScope(_ scope: LedgerRejectionScope) -> String {
    switch scope {
    case .never: "never"
    case .notNow: "not during this volume"
    case .notThisVersion: "not while what it changes stays as it is"
    }
  }

  /// The reference slices by UTF-16 unit; a cut through a surrogate pair leaves a lone surrogate there and drops the half here.
  // novel-chat-context.ts:162
  private static func turnedDownGroup(_ entries: [ChatPackLedgerEntry]) -> LineGroup {
    let ideas = entries.filter(isTurnedDownIdea)
    let recent = Array(ideas.suffix(turnedDownLimit))
    let shown = recent.count < ideas.count ? " (the \(recent.count) most recent of \(ideas.count))" : ""
    let lines = recent.map { entry -> String in
      let statement = entry.statement.jsReplace(Pattern.whitespaceRun, " ").jsTrim()
      let cut = statement.jsLength > turnedDownChars ? "\(statement.jsSlice(0, turnedDownChars - 1))…" : statement
      return "- \(cut) (\(entry.rejectionScope.map(turnedDownScope) ?? ""))"
    }
    return LineGroup(heading: "### Suggestions the author turned down — do not offer them again, nor close variants\(shown)", lines: lines)
  }

  // novel-chat-context.ts:174
  private static func decisionLine(_ entry: ChatPackLedgerEntry) -> String {
    let why = present(entry.why).map { " — why: \($0)" } ?? ""
    let forWriter = present(entry.writerLine).map { " — for the writer: \($0)" } ?? ""
    return "- \(entry.topic): \(entry.statement)\(why)\(forWriter)"
  }

  // novel-chat-context.ts:180
  private static func directionLine(_ entry: ChatPackLedgerEntry) -> String {
    "- [\(entry.topic)] \(entry.statement)\(present(entry.why).map { " — \($0)" } ?? "")"
  }

  // novel-chat-context.ts:184
  private static func isAuthorsOwn(_ entry: ChatPackLedgerEntry) -> Bool {
    entry.kind == .direction || (isDecidedKind(entry.kind) && entry.decidedBy == .author)
  }

  // novel-chat-context.ts:189
  static func renderNotebook(_ all: [ChatPackLedgerEntry], maxTokens: Int = Cap.notebook) -> String {
    let entries = all.filter { NotebookTopics.isVisibleInNotebook($0.topic) }
    if entries.isEmpty { return "Nothing has been decided yet." }
    let decided = entries.filter { isDecidedKind($0.kind) }
    let doNotPropose =
      entries.filter { $0.kind == .rejected && !isTurnedDownIdea($0) }.map { "- \($0.statement)\(present($0.why).map { " (the author's reason: \($0))" } ?? "")" }
      + decided.flatMap { entry in entry.rejectedAlternatives.map { "- \($0) (passed over for \(entry.topic))" } }
    let groups = [
      LineGroup(heading: "### The author's decisions and directions", lines: entries.filter(isAuthorsOwn).map { $0.kind == .direction ? directionLine($0) : decisionLine($0) }),
      LineGroup(heading: "### Do not propose", lines: doNotPropose),
      turnedDownGroup(entries),
      LineGroup(heading: "### Decided by the system", lines: decided.filter { $0.decidedBy == .system }.map(decisionLine)),
      LineGroup(heading: "### Backlog — not yet", lines: entries.filter { $0.kind == .backlog }.map(directionLine)),
    ]
    return fitGroups(groups.filter { !$0.lines.isEmpty }, maxTokens: maxTokens, leftOut: "Notebook entries left out: the oldest in each group")
  }
}
