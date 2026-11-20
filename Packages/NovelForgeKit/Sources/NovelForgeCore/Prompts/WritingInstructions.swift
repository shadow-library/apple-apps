import ShadowText

private let newlineRuns = ProseRegex.literal(#"\r\n?"#, "g")
private let blankLineRuns = ProseRegex.literal(#"\n{3,}"#, "g")

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:264
private func normalizeLines(_ text: String) -> String {
  text.jsReplace(newlineRuns, "\n").jsSplit("\n").map { $0.jsTrimEnd() }.joined(separator: "\n").jsTrim()
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:273
private let embeddedDefaults: [String] = ([defaultWritingInstructions] + legacyDefaultWritingInstructions).map(normalizeLines).enumerated()
  .sorted { left, right in
    let (leftLength, rightLength) = (left.element.utf16.count, right.element.utf16.count)
    return leftLength != rightLength ? leftLength > rightLength : left.offset < right.offset
  }
  .map(\.element)

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:277
private let nearCopyLineShare = 0.6

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:279
private func lineKey(_ line: String) -> JSString {
  JSString(line.jsTrim().jsReplace(ProseRegex.whitespaceRunGlobal, " "))
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:283
private let defaultLineSets: [Set<JSString>] = embeddedDefaults.map { text in
  Set(text.jsSplit("\n").map(lineKey).filter { !$0.value.isEmpty })
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:286
private func withoutNearCopies(_ text: String) -> String {
  let lines = text.jsSplit("\n")
  let keys = Set(lines.map(lineKey))
  let copied = defaultLineSets.filter { Double($0.filter { keys.contains($0) }.count) / Double($0.count) >= nearCopyLineShare }
  guard !copied.isEmpty else { return text }
  return lines.filter { line in !copied.contains { $0.contains(lineKey(line)) } }.joined(separator: "\n")
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:294
let projectAdditionsHeading =
  "PROJECT ADDITIONS\nThe author of this novel added the rules below. Where they conflict with the default above, follow these."

private let additionsPrefix = "\n\n\(projectAdditionsHeading)\n\n"

struct ResolvedWritingInstructions: Equatable, Sendable {
  let additions: String?
  let removedDefaultCopy: Bool
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:309
func resolveWritingInstructions(_ stored: String?) -> ResolvedWritingInstructions {
  guard let stored, !stored.isEmpty else { return ResolvedWritingInstructions(additions: nil, removedDefaultCopy: false) }
  let normalized = normalizeLines(stored)
  var additions = normalized
  for embedded in embeddedDefaults { additions = additions.jsSplit(embedded).joined(separator: "\n\n") }
  additions = withoutNearCopies(additions)
  let collapsed = additions.jsReplace(blankLineRuns, "\n\n").jsTrim()
  return ResolvedWritingInstructions(
    additions: collapsed.isEmpty ? nil : collapsed, removedDefaultCopy: !collapsed.jsEquals(normalized.jsReplace(blankLineRuns, "\n\n")))
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:319
func writingInstructionAdditions(_ stored: String?) -> String? {
  resolveWritingInstructions(stored).additions
}

// apps/novel-forge-server/src/modules/ai/prompts/writing-instructions.ts:332
func effectiveWritingInstructions(additions: String?, maxTokens: Int? = nil) -> TruncatedText {
  guard let additions, !additions.isEmpty else { return TruncatedText(text: defaultWritingInstructions, truncated: false) }
  guard let maxTokens else { return TruncatedText(text: "\(defaultWritingInstructions)\(additionsPrefix)\(additions)", truncated: false) }
  let room = max(0, maxTokens - countTokens("\(defaultWritingInstructions)\(additionsPrefix)"))
  let fitted = truncateAtParagraph(additions, maxTokens: room)
  guard !fitted.text.isEmpty else { return TruncatedText(text: defaultWritingInstructions, truncated: true) }
  return TruncatedText(text: "\(defaultWritingInstructions)\(additionsPrefix)\(fitted.text)", truncated: fitted.truncated)
}
