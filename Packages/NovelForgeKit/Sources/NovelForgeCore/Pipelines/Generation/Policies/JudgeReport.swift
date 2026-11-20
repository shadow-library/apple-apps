import ShadowCore
import ShadowText

struct JudgeReport: Equatable, Sendable {
  var verdict: GenerationVerdict
  var findings: [GenerationFinding]
  var endingCompliance: JudgeCompliance?
  var knowledgeCompliance: JudgeCompliance?
  var briefCompliance: JudgeCompliance?
  var readabilityCompliance: JudgeCompliance?
}

enum JudgeReportError: ShadowError, Equatable {
  case noJSONObject
  case invalid(issue: String)

  var code: String {
    switch self {
    case .noJSONObject: "judge-report.no-json-object"
    case .invalid: "judge-report.invalid"
    }
  }

  var errorDescription: String? {
    switch self {
    case .noJSONObject: "The judge reply holds no JSON object."
    case .invalid(let issue): "The judge reply does not match the judge schema: \(issue)."
    }
  }
}

extension JudgeReport {
  // apps/novel-forge-server/src/modules/ai/graphs/chapter-generation.graph.ts:339
  static func parse(_ raw: String) throws(JudgeReportError) -> JudgeReport {
    var firstIssue: String?
    for candidate in candidates(in: raw) {
      do {
        return try report(from: candidate)
      } catch {
        firstIssue = firstIssue ?? error.issue
      }
    }
    guard let firstIssue else { throw .noJSONObject }
    throw .invalid(issue: firstIssue)
  }

  private struct Violation: Error {
    let issue: String
  }

  private static let rootKeys: Set<String> = ["verdict", "findings", "endingCompliance", "knowledgeCompliance", "briefCompliance", "readabilityCompliance"]

  private static func candidates(in raw: String) -> [OrderedJSON] {
    let whole = (try? OrderedJSON(parsing: raw)).map { [$0] } ?? []
    return whole + extractJSONObjects(raw)
  }

  // apps/novel-forge-server/src/modules/ai/json-extract.ts:7
  private static func extractJSONObjects(_ text: String) -> [OrderedJSON] {
    let bytes = Array(text.utf8)
    var objects: [OrderedJSON] = []
    var depth = 0
    var start = -1
    var inString = false
    var escaped = false
    for (index, byte) in bytes.enumerated() {
      if inString {
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }
        continue
      }
      if byte == UInt8(ascii: "\"") {
        if depth > 0 { inString = true }
        continue
      }
      if byte == UInt8(ascii: "{") {
        if depth == 0 { start = index }
        depth += 1
      } else if byte == UInt8(ascii: "}") && depth > 0 {
        depth -= 1
        if depth > 0 || start == -1 { continue }
        let block = String(decoding: bytes[start...index], as: UTF8.self)
        start = -1
        if let parsed = try? OrderedJSON(parsing: block) { objects.append(parsed) }
      }
    }
    return objects
  }

  private static func report(from json: OrderedJSON) throws(Violation) -> JudgeReport {
    guard let root = json.objectValue else { throw Violation(issue: "the reply is not an object") }
    if let extra = root.keys.first(where: { !rootKeys.contains($0) }) { throw Violation(issue: "unexpected property \(extra)") }
    guard let verdictText = root["verdict"]?.stringValue, let verdict = GenerationVerdict(rawValue: verdictText) else { throw Violation(issue: "verdict is missing or unknown") }
    guard let findingValues = root["findings"]?.arrayValue else { throw Violation(issue: "findings is missing or not an array") }
    var findings: [GenerationFinding] = []
    for value in findingValues { findings.append(try finding(from: value)) }
    if verdict == .contradiction && !findings.contains(where: { $0.severity == .hard }) { throw Violation(issue: "a contradiction needs at least one hard finding") }
    return JudgeReport(
      verdict: verdict, findings: findings,
      endingCompliance: try compliance(root["endingCompliance"], "endingCompliance"), knowledgeCompliance: try compliance(root["knowledgeCompliance"], "knowledgeCompliance"),
      briefCompliance: try compliance(root["briefCompliance"], "briefCompliance"), readabilityCompliance: try compliance(root["readabilityCompliance"], "readabilityCompliance")
    )
  }

  private static func finding(from json: OrderedJSON) throws(Violation) -> GenerationFinding {
    guard let object = json.objectValue, object.keys.allSatisfy({ $0 == "severity" || $0 == "text" }) else {
      throw Violation(issue: "a finding is not an object of severity and text")
    }
    guard let severityText = object["severity"]?.stringValue, let severity = CheckSeverity(rawValue: severityText) else {
      throw Violation(issue: "a finding has no valid severity")
    }
    guard let text = object["text"]?.stringValue else { throw Violation(issue: "a finding has no text") }
    return GenerationFinding(severity: severity, text: text)
  }

  private static func compliance(_ json: OrderedJSON?, _ name: String) throws(Violation) -> JudgeCompliance? {
    guard let json else { return nil }
    guard let object = json.objectValue, object.keys.allSatisfy({ $0 == "compliant" || $0 == "issues" }) else {
      throw Violation(issue: "\(name) is not an object of compliant and issues")
    }
    guard case .bool(let compliant)? = object["compliant"] else { throw Violation(issue: "\(name).compliant is not a boolean") }
    guard let values = object["issues"]?.arrayValue else { throw Violation(issue: "\(name).issues is not an array") }
    let issues = values.compactMap(\.stringValue)
    guard issues.count == values.count else { throw Violation(issue: "\(name).issues holds a non-string") }
    return JudgeCompliance(compliant: compliant, issues: issues)
  }
}
