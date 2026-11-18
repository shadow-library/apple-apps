import Foundation
import ShadowCore

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:14; `json` is the reference's stored shape, absent optionals left out.
enum ProposedChange: Sendable {
  case entity(Entity)
  case appearance(entityKey: String)
  case characterState(CharacterState)
  case relationship(Relationship)
  case thread(PlotThread)
  case mystery(Mystery)
  case knowledge(Knowledge)
  case milestone(Milestone)
  case summary(text: String)

  struct Entity: Sendable {
    var entityKey: String
    var name: String
    var type: EntityType
    var notes: String?
  }

  struct CharacterState: Sendable {
    var entityKey: String
    var location: String?
    var conditions: [String]?
    var immediateGoal: String?
    var statusNote: String?
    var evidence: String
  }

  struct Relationship: Sendable {
    var entityKey: String
    var targetKey: String
    var kind: String
    var note: String?
    var evidence: String
  }

  struct PlotThread: Sendable {
    var threadKey: String
    var status: ThreadStatus
    var summary: String?
    var intentionallyOpen: Bool?
  }

  struct Mystery: Sendable {
    var mysteryKey: String
    var status: MysteryStatus
    var question: String?
    var intentionallyOpen: Bool?
    var truthFactKey: String?
  }

  struct Knowledge: Sendable {
    var entityKey: String
    var factKey: String
    var how: String
  }

  struct Milestone: Sendable {
    var milestoneKey: String
    var reached: Bool
  }

  var category: FinalizeCategory {
    switch self {
    case .entity: .entity
    case .appearance: .appearance
    case .characterState: .characterState
    case .relationship: .relationship
    case .thread, .mystery: .promise
    case .knowledge: .knowledge
    case .milestone: .milestone
    case .summary: .summary
    }
  }

  // apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:85
  var itemKey: String {
    switch self {
    case .entity(let entity): "entity:\(entity.entityKey)"
    case .appearance(let entityKey): "appearance:\(entityKey)"
    case .characterState(let state): "character_state:\(state.entityKey)"
    case .relationship(let relationship): "relationship:\(relationship.entityKey):\(relationship.targetKey):\(relationship.kind)"
    case .thread(let thread): "promise:thread:\(thread.threadKey)"
    case .mystery(let mystery): "promise:mystery:\(mystery.mysteryKey)"
    case .knowledge(let knowledge): "knowledge:\(knowledge.entityKey):\(knowledge.factKey)"
    case .milestone(let milestone): "milestone:\(milestone.milestoneKey)"
    case .summary: "summary"
    }
  }

  /// Lowercase sha256 hex of the RFC 8785 canonical `json`: equal exactly when the reference's `sameProposal` holds, so an answer can name the change it saw.
  var digest: String {
    sha256Hex(String(decoding: CanonicalJSON.encode(json), as: UTF8.self))
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:122
func sameProposal(_ left: ProposedChange, _ right: ProposedChange) -> Bool {
  CanonicalJSON.encode(left.json) == CanonicalJSON.encode(right.json)
}

extension ProposedChange: Equatable {
  static func == (left: ProposedChange, right: ProposedChange) -> Bool {
    sameProposal(left, right)
  }
}

extension ProposedChange: JSONRepresentable {
  var json: JSONValue {
    switch self {
    case .entity(let entity):
      .object([
        "category": "entity",
        "entity": .object(present(["entityKey": .string(entity.entityKey), "name": .string(entity.name), "type": .string(entity.type.rawValue), "notes": text(entity.notes)])),
      ])
    case .appearance(let entityKey):
      .object(["category": "appearance", "entityKey": .string(entityKey)])
    case .characterState(let state):
      .object([
        "category": "character_state",
        "state": .object(
          present([
            "entityKey": .string(state.entityKey), "location": text(state.location), "conditions": state.conditions.map { .array($0.map(JSONValue.string)) },
            "immediateGoal": text(state.immediateGoal), "statusNote": text(state.statusNote), "evidence": .string(state.evidence),
          ])),
      ])
    case .relationship(let relationship):
      .object([
        "category": "relationship",
        "relationship": .object(
          present([
            "entityKey": .string(relationship.entityKey), "targetKey": .string(relationship.targetKey), "kind": .string(relationship.kind), "note": text(relationship.note),
            "evidence": .string(relationship.evidence),
          ])),
      ])
    case .thread(let thread):
      .object([
        "category": "promise",
        "thread": .object(
          present([
            "threadKey": .string(thread.threadKey), "status": .string(thread.status.rawValue), "summary": text(thread.summary),
            "intentionallyOpen": thread.intentionallyOpen.map(JSONValue.bool),
          ])),
      ])
    case .mystery(let mystery):
      .object([
        "category": "promise",
        "mystery": .object(
          present([
            "mysteryKey": .string(mystery.mysteryKey), "status": .string(mystery.status.rawValue), "question": text(mystery.question),
            "intentionallyOpen": mystery.intentionallyOpen.map(JSONValue.bool), "truthFactKey": text(mystery.truthFactKey),
          ])),
      ])
    case .knowledge(let knowledge):
      .object(["category": "knowledge", "entityKey": .string(knowledge.entityKey), "factKey": .string(knowledge.factKey), "how": .string(knowledge.how)])
    case .milestone(let milestone):
      .object(["category": "milestone", "milestoneKey": .string(milestone.milestoneKey), "reached": .bool(milestone.reached)])
    case .summary(let text):
      .object(["category": "summary", "text": .string(text)])
    }
  }

  init?(json: JSONValue) {
    guard let fields = json.objectValue, let category = fields["category"]?.stringValue else { return nil }
    switch category {
    case "entity":
      guard let entity = fields["entity"].flatMap(Entity.init(json:)) else { return nil }
      self = .entity(entity)
    case "appearance":
      guard let entityKey = fields["entityKey"]?.stringValue else { return nil }
      self = .appearance(entityKey: entityKey)
    case "character_state":
      guard let state = fields["state"].flatMap(CharacterState.init(json:)) else { return nil }
      self = .characterState(state)
    case "relationship":
      guard let relationship = fields["relationship"].flatMap(Relationship.init(json:)) else { return nil }
      self = .relationship(relationship)
    case "promise":
      if let thread = fields["thread"] {
        guard let parsed = PlotThread(json: thread) else { return nil }
        self = .thread(parsed)
      } else {
        guard let mystery = fields["mystery"].flatMap(Mystery.init(json:)) else { return nil }
        self = .mystery(mystery)
      }
    case "knowledge":
      guard let entityKey = fields["entityKey"]?.stringValue, let factKey = fields["factKey"]?.stringValue, let how = fields["how"]?.stringValue else { return nil }
      self = .knowledge(Knowledge(entityKey: entityKey, factKey: factKey, how: how))
    case "milestone":
      guard let milestoneKey = fields["milestoneKey"]?.stringValue, let reached = fields["reached"]?.boolValue else { return nil }
      self = .milestone(Milestone(milestoneKey: milestoneKey, reached: reached))
    case "summary":
      guard let text = fields["text"]?.stringValue else { return nil }
      self = .summary(text: text)
    default:
      return nil
    }
  }
}

private func text(_ value: String?) -> JSONValue? {
  value.map(JSONValue.string)
}

private func present(_ fields: [String: JSONValue?]) -> [String: JSONValue] {
  fields.compactMapValues { $0 }
}

private struct OptionalField<Value> {
  let value: Value?
  let valid: Bool
}

private func optional<Value>(_ fields: [String: JSONValue], _ key: String, _ read: (JSONValue) -> Value?) -> OptionalField<Value> {
  guard let raw = fields[key], !raw.isNull else { return OptionalField(value: nil, valid: true) }
  let value = read(raw)
  return OptionalField(value: value, valid: value != nil)
}

private func strings(_ value: JSONValue) -> [String]? {
  guard let items = value.arrayValue else { return nil }
  let texts = items.compactMap(\.stringValue)
  return texts.count == items.count ? texts : nil
}

extension ProposedChange.Entity {
  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let entityKey = fields["entityKey"]?.stringValue, let name = fields["name"]?.stringValue,
      let type = fields["type"]?.stringValue.flatMap(EntityType.init(rawValue:))
    else { return nil }
    let notes = optional(fields, "notes", \.stringValue)
    guard notes.valid else { return nil }
    self.init(entityKey: entityKey, name: name, type: type, notes: notes.value)
  }
}

extension ProposedChange.CharacterState {
  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let entityKey = fields["entityKey"]?.stringValue, let evidence = fields["evidence"]?.stringValue else { return nil }
    let location = optional(fields, "location", \.stringValue)
    let conditions = optional(fields, "conditions", strings)
    let immediateGoal = optional(fields, "immediateGoal", \.stringValue)
    let statusNote = optional(fields, "statusNote", \.stringValue)
    guard location.valid, conditions.valid, immediateGoal.valid, statusNote.valid else { return nil }
    self.init(entityKey: entityKey, location: location.value, conditions: conditions.value, immediateGoal: immediateGoal.value, statusNote: statusNote.value, evidence: evidence)
  }
}

extension ProposedChange.Relationship {
  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let entityKey = fields["entityKey"]?.stringValue, let targetKey = fields["targetKey"]?.stringValue,
      let kind = fields["kind"]?.stringValue, let evidence = fields["evidence"]?.stringValue
    else { return nil }
    let note = optional(fields, "note", \.stringValue)
    guard note.valid else { return nil }
    self.init(entityKey: entityKey, targetKey: targetKey, kind: kind, note: note.value, evidence: evidence)
  }
}

extension ProposedChange.PlotThread {
  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let threadKey = fields["threadKey"]?.stringValue, let status = fields["status"]?.stringValue.flatMap(ThreadStatus.init(rawValue:)) else {
      return nil
    }
    let summary = optional(fields, "summary", \.stringValue)
    let intentionallyOpen = optional(fields, "intentionallyOpen", \.boolValue)
    guard summary.valid, intentionallyOpen.valid else { return nil }
    self.init(threadKey: threadKey, status: status, summary: summary.value, intentionallyOpen: intentionallyOpen.value)
  }
}

extension ProposedChange.Mystery {
  fileprivate init?(json: JSONValue) {
    guard let fields = json.objectValue, let mysteryKey = fields["mysteryKey"]?.stringValue,
      let status = fields["status"]?.stringValue.flatMap(MysteryStatus.init(rawValue:))
    else { return nil }
    let question = optional(fields, "question", \.stringValue)
    let intentionallyOpen = optional(fields, "intentionallyOpen", \.boolValue)
    let truthFactKey = optional(fields, "truthFactKey", \.stringValue)
    guard question.valid, intentionallyOpen.valid, truthFactKey.valid else { return nil }
    self.init(mysteryKey: mysteryKey, status: status, question: question.value, intentionallyOpen: intentionallyOpen.value, truthFactKey: truthFactKey.value)
  }
}
