import Foundation
import ShadowCore

@testable import NovelForgeCore

enum FinalizeReviewFixture {
  static func load(_ name: String) throws -> OrderedJSON {
    try OrderedJSON(parsing: String(decoding: try ReferenceFixture.data("finalize-review/\(name)"), as: UTF8.self))
  }
}

extension OrderedJSON {
  var frList: [OrderedJSON] { arrayValue ?? [] }

  var frTexts: [String] { frList.compactMap(\.stringValue) }

  var frIsNull: Bool {
    guard case .null = self else { return false }
    return true
  }

  func frField(_ key: String) throws -> OrderedJSON {
    try self[key].orThrow("field \(key) in \(jsonText)")
  }

  func frText(_ key: String) throws -> String {
    try frField(key).stringValue.orThrow("text \(key) in \(jsonText)")
  }

  func frOptionalText(_ key: String) -> String? { self[key]?.stringValue }

  func frInt(_ key: String) throws -> Int {
    guard case .int(let number) = try frField(key) else { throw FixtureShapeError(description: "int \(key) in \(jsonText)") }
    return Int(number)
  }

  func frFlag(_ key: String) throws -> Bool {
    guard case .bool(let flag) = try frField(key) else { throw FixtureShapeError(description: "flag \(key) in \(jsonText)") }
    return flag
  }
}

func reviewCanonical(_ value: JSONValue) -> String {
  String(decoding: CanonicalJSON.encode(value), as: UTF8.self)
}

func reviewCanonical(_ value: OrderedJSON) -> String {
  reviewCanonical(jsonValue(value))
}

func fixtureProposal(_ value: OrderedJSON) throws -> ProposedChange {
  try ProposedChange(json: jsonValue(value)).orThrow("proposal \(value.jsonText)")
}

private func stored<Value: RawRepresentable<String>>(_ type: Value.Type, _ value: OrderedJSON?) throws -> Value? {
  guard let value, !value.frIsNull else { return nil }
  return try value.stringValue.flatMap(Value.init(rawValue:)).orThrow("\(Value.self) \(value.jsonText)")
}

private func assessed<Value: Sendable>(_ entry: OrderedJSON, _ category: String, _ member: String, _ unwrap: (ProposedChange) -> Value?) throws
  -> FinalizeExtraction.Assessed<Value>
{
  let change = try fixtureProposal(.object(OrderedJSONObject([(key: "category", value: .string(category)), (key: member, value: entry)])))
  return FinalizeExtraction.Assessed(try unwrap(change).orThrow("\(member) \(entry.jsonText)"), confidence: try stored(FinalizeExtraction.Confidence.self, entry["confidence"]))
}

func fixtureExtraction(_ json: OrderedJSON) throws -> FinalizeExtraction {
  var extraction = FinalizeExtraction()
  extraction.appeared = json["appeared"]?.frTexts ?? []
  extraction.newEntities = try (json["newEntities"]?.frList ?? []).map { entry in
    try assessed(entry, "entity", "entity") { if case .entity(let entity) = $0 { entity } else { nil } }.value
  }
  extraction.threads = try (json["threads"]?.frList ?? []).map { entry in
    try assessed(entry, "promise", "thread") { if case .thread(let thread) = $0 { thread } else { nil } }
  }
  extraction.mysteries = try (json["mysteries"]?.frList ?? []).map { entry in
    try assessed(entry, "promise", "mystery") { if case .mystery(let mystery) = $0 { mystery } else { nil } }
  }
  extraction.relationships = try (json["relationships"]?.frList ?? []).map { entry in
    try assessed(entry, "relationship", "relationship") { if case .relationship(let relationship) = $0 { relationship } else { nil } }
  }
  extraction.characterStates = try (json["characterStates"]?.frList ?? []).map { entry in
    try assessed(entry, "character_state", "state") { if case .characterState(let state) = $0 { state } else { nil } }
  }
  extraction.knowledgeChanges = try (json["knowledgeChanges"]?.frList ?? []).map { entry in
    ProposedChange.Knowledge(entityKey: try entry.frText("entityKey"), factKey: try entry.frText("factKey"), how: try entry.frText("how"))
  }
  extraction.chapterSummary = json.frOptionalText("chapterSummary")
  extraction.milestones = try (json["milestones"]?.frList ?? []).map { entry in
    FinalizeExtraction.Milestone(milestoneKey: try entry.frText("milestoneKey"), reached: try entry.frFlag("reached"), evidence: entry.frOptionalText("evidence"))
  }
  return extraction
}

private func fact(_ json: OrderedJSON) throws -> RevealFact {
  let unlock = try json.frField("unlock")
  let chapter = try json.frField("revealChapter")
  return RevealFact(
    factKey: try json.frText("factKey"), revealChapter: chapter.frIsNull ? nil : try json.frInt("revealChapter"),
    unlock: unlock.frIsNull ? nil : try UnlockCondition(validating: unlock).orThrow("unlock \(unlock.jsonText)"),
    source: try stored(FactSource.self, json["source"]).orThrow("source"))
}

func fixtureCategories(_ json: OrderedJSON?) throws -> [FinalizeCategory] {
  try (json?.frList ?? []).map { try stored(FinalizeCategory.self, $0).orThrow("category") }
}

private func promiseKeys(_ settled: [String], prefix: String) -> Set<JSString> {
  Set(settled.filter { $0.jsStartsWith(prefix) }.map { JSString(String($0.dropFirst(prefix.count))) })
}

func fixtureMaterial(_ json: OrderedJSON, extraction override: OrderedJSON? = nil, isolated: Bool? = nil, autoKeep: [FinalizeCategory]? = nil) throws -> FinalizeReviewMaterial {
  let unlock = try json.frField("unlock")
  let names = try json.frField("entityNames").frList.map { pair -> (JSString, String) in
    let parts = pair.frTexts
    guard parts.count == 2 else { throw FixtureShapeError(description: "entity name \(pair.jsonText)") }
    return (JSString(parts[0]), parts[1])
  }
  let settled = try json.frField("settledPromises").frTexts
  return FinalizeReviewMaterial(
    extraction: try fixtureExtraction(override ?? json.frField("extraction")), isolated: try isolated ?? json.frFlag("isolated"),
    claimedMilestones: try json.frField("claimedMilestones").frTexts,
    milestones: try json.frField("milestones").frList.map {
      FinalizeReviewMaterial.Milestone(
        milestoneKey: try $0.frText("milestoneKey"), label: try $0.frText("label"), state: try stored(MilestoneState.self, $0["state"]).orThrow("state"))
    },
    entityNames: Dictionary(names) { _, last in last }, closedThreads: promiseKeys(settled, prefix: "thread:"), resolvedMysteries: promiseKeys(settled, prefix: "mystery:"),
    plannedLearns: try json.frField("plannedLearns").frList.map { pair in
      let parts = pair.frTexts
      guard parts.count == 2 else { throw FixtureShapeError(description: "learn \(pair.jsonText)") }
      return FinalizeReviewMaterial.Learn(entityKey: parts[0], factKey: parts[1])
    },
    plannedFactKeys: try json.frField("plannedFactKeys").frTexts, facts: try json.frField("facts").frList.map(fact),
    unlock: UnlockContext(
      chapter: try unlock.frInt("chapter"), endingChapter: try unlock.frField("endingChapter").frIsNull ? nil : try unlock.frInt("endingChapter"),
      volumeKey: unlock.frOptionalText("volumeKey"), volumeOrdinals: [:], reachedMilestones: Set(try unlock.frField("reachedMilestones").frTexts.map { JSString($0) })),
    autoKeep: Set(try autoKeep ?? fixtureCategories(json["autoKeep"])))
}

func fixtureReviewItem(_ json: OrderedJSON) throws -> FinalizeReviewItem {
  let edited = json["edited"]
  return FinalizeReviewItem(
    itemKey: try json.frText("itemKey"), category: try stored(FinalizeCategory.self, json["category"]).orThrow("category"),
    triage: try stored(FinalizeTriage.self, json["triage"]).orThrow("triage"), basis: try stored(FinalizeBasis.self, json["basis"]).orThrow("basis"),
    subjectKey: try json.frText("subjectKey"), claim: try json.frText("claim"), evidence: json.frOptionalText("evidence"),
    proposed: try fixtureProposal(try json.frField("proposed")),
    flag: try stored(FinalizeFlag.self, json["flag"]), dependents: json["dependents"].flatMap { $0.frIsNull ? nil : $0.frTexts },
    decision: try stored(FinalizeDecision.self, json["decision"]), edited: try edited.flatMap { $0.frIsNull ? nil : try fixtureProposal($0) },
    reason: json.frOptionalText("reason"),
    autoKept: try json.frFlag("autoKept"))
}

private func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }

extension FinalizeReviewItem {
  /// The reference's `ProposedItem` shape, which carries no edit or reason.
  var proposedJSON: JSONValue {
    .object([
      "itemKey": .string(itemKey), "category": .string(category.rawValue), "triage": .string(triage.rawValue), "basis": .string(basis.rawValue), "subjectKey": .string(subjectKey),
      "claim": .string(claim), "evidence": optional(evidence), "proposed": proposed.json, "flag": optional(flag?.rawValue),
      "dependents": dependents.map { .array($0.map(JSONValue.string)) } ?? .null, "decision": optional(decision?.rawValue), "autoKept": .bool(autoKept),
    ])
  }

  var answerJSON: JSONValue {
    .object([
      "itemKey": .string(itemKey), "decision": optional(decision?.rawValue), "edited": edited?.json ?? .null, "reason": optional(reason), "autoKept": .bool(autoKept),
    ])
  }
}
