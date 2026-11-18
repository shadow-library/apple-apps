import Foundation

@testable import NovelForgeCore

struct ReviewFixtureError: Error, CustomStringConvertible {
  let description: String
}

struct ReviewFindingsFixture {
  let root: OrderedJSON
  let bodies: [String]

  static func load() throws -> ReviewFindingsFixture {
    let root = try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("review-findings/review-findings.json"), as: UTF8.self))
    return ReviewFindingsFixture(root: root, bodies: try root.field("bodies").items.map { try $0.stringValue.orFail("body") })
  }

  func rows(_ section: String) throws -> [[OrderedJSON]] {
    try root.field(section).items.map(\.items)
  }

  func body(_ json: OrderedJSON) throws -> String {
    bodies[try json.index()]
  }
}

extension Optional {
  func orFail(_ what: String) throws -> Wrapped {
    guard let self else { throw ReviewFixtureError(description: "missing \(what)") }
    return self
  }
}

extension OrderedJSON {
  var isNull: Bool {
    guard case .null = self else { return false }
    return true
  }

  var optionalText: String? { isNull ? nil : stringValue }

  func field(_ key: String) throws -> OrderedJSON { try self[key].orFail(key) }

  func index() throws -> Int { Int(try numberValue.orFail("index")) }

  var flag: Bool { if case .bool(let value) = self { value } else { false } }

  func texts() -> [String] { items.compactMap(\.stringValue) }
}

func reviewCompliance(_ json: OrderedJSON?) -> ReviewCompliance? {
  guard let json, !json.isNull else { return nil }
  return ReviewCompliance(compliant: json["compliant"]?.flag ?? false, issues: json["issues"]?.texts() ?? [])
}

func reviewFacts(_ json: OrderedJSON?) throws -> [DisclosureFact] {
  try (json?.items ?? []).map { fact in
    DisclosureFact(factKey: try fact.field("factKey").text, text: try fact.field("text").text, allowedClues: fact["allowedClues"].map { $0.texts() })
  }
}

func reviewDrafts(_ json: OrderedJSON) throws -> [DraftFinding] {
  try json.items.map { draft in
    DraftFinding(
      severity: try ReviewFindingSeverity(rawValue: draft.field("severity").text).orFail("severity"),
      category: try ReviewFindingCategory(rawValue: draft.field("category").text).orFail("category"), text: try draft.field("text").text,
      evidence: draft["evidence"]?.optionalText)
  }
}

func reviewedText(_ json: OrderedJSON) throws -> ReviewedText {
  let revision = try json.field("draftRevision")
  return ReviewedText(draftRevision: revision.isNull ? nil : String(try revision.index()), bodyHash: try json.field("bodyHash").text)
}

func findingJSON(_ finding: ReviewFinding) -> OrderedJSON {
  .record([
    ("id", .string(finding.id)), ("severity", .string(finding.severity.rawValue)), ("category", .string(finding.category.rawValue)), ("text", .string(finding.text)),
    ("evidence", .optional(finding.evidence)), ("fingerprint", .string(finding.fingerprint)),
  ])
}

func complianceJSON(_ compliance: ReviewCompliance?) -> OrderedJSON {
  guard let compliance else { return .null }
  return .record([("compliant", .bool(compliance.compliant)), ("issues", .strings(compliance.issues))])
}

func outcomeJSON(_ outcome: ReviewOutcome) -> OrderedJSON {
  .record([
    ("verdict", .optional(outcome.verdict)), ("note", .optional(outcome.note)), ("checked", .strings(outcome.checked)),
    ("briefCompliance", complianceJSON(outcome.briefCompliance)),
    ("readabilityCompliance", complianceJSON(outcome.readabilityCompliance)), ("endingCompliance", complianceJSON(outcome.endingCompliance)),
    ("knowledgeCompliance", complianceJSON(outcome.knowledgeCompliance)), ("disposition", .string(outcome.disposition.rawValue)),
    ("findings", .array(outcome.findings.map(findingJSON))),
  ])
}

func expectedOutcome(_ json: OrderedJSON) throws -> (shape: OrderedJSON, metrics: [String: Double]?) {
  let object = try json.objectValue.orFail("outcome")
  let metrics = object["metrics"]?.objectValue.map { fields in Dictionary(uniqueKeysWithValues: fields.entries.map { ($0.key, $0.value.numberValue ?? .nan) }) }
  return (.object(OrderedJSONObject(object.entries.filter { $0.key != "metrics" }.map { (key: $0.key, value: $0.value) })), metrics)
}
