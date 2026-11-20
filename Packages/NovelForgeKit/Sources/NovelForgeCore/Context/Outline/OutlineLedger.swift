import ShadowCore
import ShadowText

private let emptyLedger = "Nothing has been decided yet."

private func isDecided(_ entry: ChatPackLedgerEntry) -> Bool {
  entry.kind == .decision || entry.kind == .system
}

private func tagged(_ entry: ChatPackLedgerEntry) -> String {
  let why = ChatPack.present(entry.why).map { " — \($0)" } ?? ""
  return "- [\(entry.topic)] \(entry.statement)\(why)"
}

private func decision(_ entry: ChatPackLedgerEntry) -> String {
  let by = entry.decidedBy == .system ? " (decided by the system)" : ""
  var lines = ["- \(entry.topic)\(by): \(entry.statement)"]
  if let why = ChatPack.present(entry.why) { lines.append("  Why: \(why)") }
  if let line = ChatPack.present(entry.writerLine) { lines.append("  For the writer: \(line)") }
  return lines.joined(separator: "\n")
}

private func list(_ heading: String, _ lines: [String]) -> String? {
  lines.isEmpty ? nil : "### \(heading)\n\n\(lines.joined(separator: "\n"))"
}

private func doNotPropose(_ entries: [ChatPackLedgerEntry]) -> [String] {
  let rejected = entries.filter { $0.kind == .rejected }.map { "- \($0.statement)\(ChatPack.present($0.why).map { " (the author's reason: \($0))" } ?? "")" }
  let passedOver = entries.filter(isDecided).flatMap { entry in entry.rejectedAlternatives.map { "- \($0) (passed over for \(entry.topic))" } }
  return rejected + passedOver
}

extension ChatPack {
  /// Rejected ideas and the alternatives a decision passed over reach the model only as things never to offer again.
  // apps/novel-forge-server/src/modules/ledger/ledger-sections.ts:60 (renderLedger)
  static func renderLedger(_ all: [ChatPackLedgerEntry]) -> String {
    let entries = all.filter { NotebookTopics.isVisibleInNotebook($0.topic) }
    let blocks = [
      list("Decisions", entries.filter(isDecided).map(decision)),
      list("Author directions", entries.filter { $0.kind == .direction }.map(tagged)),
      list("Backlog — not yet", entries.filter { $0.kind == .backlog }.map(tagged)),
      list("Do not propose", doNotPropose(entries)),
    ].compactMap { $0 }
    return blocks.isEmpty ? emptyLedger : blocks.joined(separator: "\n\n")
  }

  /// The active ledger carries the author's decisions and do-not-propose list, so it is required and never evicted to fit a budget.
  // apps/novel-forge-server/src/modules/ledger/ledger-sections.ts:101 (ledgerSection)
  static func ledgerSection(_ all: [ChatPackLedgerEntry], segment: ChatPackSegment = .stable) -> ChatPackSection {
    let rendered = renderSection("ledger", renderLedger(all))
    let refs = all.filter { NotebookTopics.isVisibleInNotebook($0.topic) }.map { "ledger:\($0.topic)" }.jsUnique()
    return ChatPackSection(
      key: "ledger", tier: .approvedIntent, segment: segment, tokens: countTokens(rendered), truncated: false, sourceRefs: refs, rendered: rendered, required: true)
  }
}
