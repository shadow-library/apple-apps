enum JudgeNote {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:711
  static func render(findings: [GenerationFinding], readabilityNote: String?) -> String? {
    let lines = findings.map { "[\($0.severity.rawValue)] \($0.text)" } + [readabilityNote ?? ""]
    let note = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    return note.isEmpty ? nil : note
  }
}
