import ShadowText

enum FindingRepetition {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:232
  static func normalized(_ text: String) -> String {
    text.jsToLowerCase().jsTrim().jsReplace(ProseRegex.whitespaceRunGlobal, " ")
  }

  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:236
  static func isRepeated(_ findings: [GenerationFinding], previous: [GenerationFinding]) -> Bool {
    guard !previous.isEmpty else { return false }
    let earlier = previous.map { (severity: $0.severity, text: normalized($0.text)) }
    return findings.contains { finding in
      let text = normalized(finding.text)
      return earlier.contains { $0.severity == finding.severity && $0.text.jsEquals(text) }
    }
  }
}
