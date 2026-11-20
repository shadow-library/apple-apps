import ShadowText

private let writerLinesBudget = 1_200

extension WriterRender {
  // apps/novel-forge-server/src/modules/ledger/ledger-sections.ts:79
  private static func selectWithinBudget(_ lines: [String], budgetTokens: Int) -> [String] {
    var kept: [String] = []
    var used = 0
    for line in lines.reversed() {
      let cost = countTokens("- \(line)\n")
      if used + cost > budgetTokens { continue }
      used += cost
      kept.append(line)
    }
    return kept.reversed()
  }

  /// The author's decided lines, newest first within the budget, scrubbed for the writer.
  // ledger-sections.ts:116
  static func writerLines(_ entries: [ChatPackLedgerEntry], disclosure: inout WriterDisclosurePolicy) throws(DisclosureError) -> WriterRendered {
    var rendered = WriterRendered()
    let withLines = entries.filter { ($0.kind == .decision || $0.kind == .system) && ChatPack.present($0.writerLine) != nil }
    var lines: [String] = []
    for entry in withLines {
      let line = try disclosure.scrub(entry.writerLine ?? "", .writerLine).jsTrim()
      if !line.isEmpty { lines.append(line) }
    }
    let kept = selectWithinBudget(lines, budgetTokens: writerLinesBudget)
    if kept.isEmpty { return rendered }
    let content = renderSection("writer_lines", kept.map { "- \($0)" }.joined(separator: "\n"))
    let refs = withLines.map { "ledger:\($0.topic)" }.jsUnique()
    let section = ChatPackSection(
      key: "writer_lines", tier: .approvedIntent, segment: .volatile, tokens: countTokens(content), truncated: kept.count < lines.count, sourceRefs: refs, rendered: content)
    rendered.reserve(section, name: "the author's decisions for the writer", cap: Cap.writerLines)
    return rendered
  }
}
