import ShadowText

private let hiddenThreadPlaceholder = "keep the hidden thread unresolved"
private let factPrefix = "fact:"

// apps/novel-forge-server/src/modules/ai/schemas/ending-contract.schema.ts:36
func renderEndingContract(_ contract: ChapterEndingContract?, factWriterNotes: [JSString: String?]? = nil) -> String {
  guard let contract else { return "" }
  var lines = [
    "Hook type: \(contract.hookType.rawValue)", "Emotional beat: \(contract.emotionalBeat)", "Open question: \(contract.openQuestion)",
    "Handoff state: \(contract.handoffState)",
  ]
  let entries = contract.mustNotResolve ?? []
  let rendered = factWriterNotes.map { writerSafeEntries(entries, $0) } ?? entries
  if !rendered.isEmpty { lines.append("Must NOT resolve: \(rendered.joined(separator: ", "))") }
  return lines.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/ai/schemas/ending-contract.schema.ts:26
private func mustNotResolveFactKey(_ entry: String, _ factKeys: Set<JSString>) -> String? {
  if entry.jsStartsWith(factPrefix) { return entry.jsSlice(factPrefix.jsLength).jsTrim() }
  let trimmed = entry.jsTrim()
  return factKeys.contains(JSString(trimmed)) ? trimmed : nil
}

// apps/novel-forge-server/src/modules/ai/schemas/ending-contract.schema.ts:46
private func writerSafeEntries(_ entries: [String], _ notes: [JSString: String?]) -> [String] {
  let factKeys = Set(notes.keys)
  return entries.map { entry in
    guard let key = mustNotResolveFactKey(entry, factKeys) else { return entry }
    let note = (notes[JSString(key)] ?? nil)?.jsTrim() ?? ""
    return note.isEmpty ? hiddenThreadPlaceholder : note
  }.jsUnique()
}
