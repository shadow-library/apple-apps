import ShadowText

protocol WriterTextScrubbing {
  mutating func scrub(_ text: String, _ field: WriterField) throws(DisclosureError) -> String
  mutating func scrubLeakLine(_ line: String) throws(DisclosureError) -> String
}

extension WriterDisclosurePolicy: WriterTextScrubbing {}

enum WriterFacingFindings {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:332
  static func render<Scrubber: WriterTextScrubbing>(
    findings: [GenerationFinding], knowledgeWriterFindings: [GenerationFinding], scrubber: inout Scrubber
  ) throws(DisclosureError) -> String {
    let others = try scrubber.scrub(lines(findings.filter { !$0.text.jsStartsWith(knowledgeLeakPrefix) }), .note)
    var leaks: [GenerationFinding] = []
    for finding in knowledgeWriterFindings {
      let text = try scrubber.scrubLeakLine(finding.text)
      leaks.append(GenerationFinding(severity: finding.severity, text: text))
    }
    return [others, lines(leaks)].filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func lines(_ findings: [GenerationFinding]) -> String {
    findings.map { "[\($0.severity.rawValue)] \($0.text)" }.joined(separator: "\n")
  }
}
