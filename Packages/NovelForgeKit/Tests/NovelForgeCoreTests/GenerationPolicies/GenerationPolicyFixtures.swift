import Foundation

@testable import NovelForgeCore

struct FindingFixture: Decodable {
  let severity: String
  let text: String

  var finding: GenerationFinding { GenerationFinding(severity: CheckSeverity(rawValue: severity) ?? .soft, text: text) }
}

extension [FindingFixture] {
  var findings: [GenerationFinding] { map(\.finding) }
}

struct ComplianceFixture: Decodable {
  let compliant: Bool
  let issues: [String]

  var compliance: JudgeCompliance { JudgeCompliance(compliant: compliant, issues: issues) }
}

struct LeakFixture: Decodable {
  let factKey: String
  let term: String
  let excerpt: String

  var leak: KnowledgeLeakIssue { KnowledgeLeakIssue(factKey: factKey, term: term, excerpt: excerpt) }
}

struct FactFixture: Decodable {
  let factKey: String
  let text: String
  let constraintNote: String?
  let writerNote: String?

  var fact: DisclosureFact { DisclosureFact(factKey: factKey, text: text, constraintNote: constraintNote, writerNote: writerNote) }
}

struct RecordingScrubber: WriterTextScrubbing {
  var calls: [String] = []

  mutating func scrub(_ text: String, _ field: WriterField) throws(DisclosureError) -> String {
    calls.append("\(field.rawValue)|\(text)")
    return text.replacingOccurrences(of: "Moriarty", with: "[withheld:\(field.rawValue)]", options: .literal)
  }

  mutating func scrubLeakLine(_ line: String) throws(DisclosureError) -> String {
    calls.append("leak|\(line)")
    return line.replacingOccurrences(of: "forgery", with: "[leak]", options: .literal)
  }
}

enum GenerationFixtures {
  static func load<Value: Decodable>(_ name: String) throws -> Value {
    try ReferenceFixture.decode(Value.self, from: "generation-policies/\(name).json")
  }
}
