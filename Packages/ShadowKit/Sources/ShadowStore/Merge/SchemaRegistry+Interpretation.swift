import ShadowCore

struct Interpretation {
  let state: EntityState?
  let foreign: ChangeRecord?

  static func wholly(_ change: ChangeRecord) -> Interpretation {
    Interpretation(state: nil, foreign: change)
  }
}

extension SchemaRegistry {
  private static let reviseMembers = ["revision", "parent", "body", "created", "generation", "head", "marks"]

  public func isInterpretable(_ change: ChangeRecord) -> Bool {
    interpretation(of: change).foreign == nil
  }

  public func foreignPart(of change: ChangeRecord) -> ChangeRecord? {
    interpretation(of: change).foreign
  }

  func interpretation(of change: ChangeRecord) -> Interpretation {
    guard let schema = self[change.entity] else { return .wholly(change) }
    switch (change.kind, schema.shape) {
    case (.purge, _):
      guard change.fields.isEmpty else { return .wholly(change) }
      return Interpretation(state: .purged(PurgedState(clock: change.clock)), foreign: nil)
    case (.set, .record), (.set, .revisioned):
      return split(change, schema: schema)
    case (.append, .appended):
      return Interpretation(state: .appended(AppendedState(item: change.fields, clock: change.clock)), foreign: nil)
    case (.revise, .revisioned):
      guard let state = revision(change, schema: schema) else { return .wholly(change) }
      return Interpretation(state: state, foreign: nil)
    default:
      return .wholly(change)
    }
  }

  private func split(_ change: ChangeRecord, schema: EntitySchema) -> Interpretation {
    var known = [ExactString: FieldState]()
    var unknown = [String: JSONValue]()
    for (name, value) in change.fields {
      guard let rule = schema.rule(forField: name), rule.admits(value) else {
        unknown[name] = value
        continue
      }
      known[ExactString(name)] = FieldState(value: value, clock: change.clock, rule: rule)
    }
    let remainder = unknown.isEmpty ? nil : change.restricted(to: unknown)
    guard !known.isEmpty else { return Interpretation(state: nil, foreign: remainder) }
    let state: EntityState =
      switch schema.shape {
      case .revisioned: .revisioned(RevisionedState(fields: known, head: nil, marks: [:], revisions: [:]))
      default: .record(RecordState(fields: known))
      }
    return Interpretation(state: state, foreign: remainder)
  }

  private func revision(_ change: ChangeRecord, schema: EntitySchema) -> EntityState? {
    let fields = change.fields
    guard fields.keys.allSatisfy({ name in Self.reviseMembers.contains { $0.utf8.elementsEqual(name.utf8) } }) else { return nil }
    guard let revision = fields["revision"]?.stringValue, let body = fields["body"], let created = fields["created"]?.stringValue.flatMap(HLCTimestamp.init),
      let generation = fields["generation"]?.intValue, generation >= 0
    else { return nil }
    let parent: String?
    switch fields["parent"] {
    case .string(let text): parent = text
    case .null: parent = nil
    default: return nil
    }
    let item = RevisionItem(parent: parent, body: body, created: created, generation: generation)
    guard item.id.utf8.elementsEqual(revision.utf8) else { return nil }
    let becomesHead: Bool
    switch fields["head"] {
    case nil: becomesHead = true
    case .bool(let flag): becomesHead = flag
    default: return nil
    }
    let marks: [ExactString]
    switch fields["marks"] {
    case nil: marks = []
    case .array(let names):
      let texts = names.compactMap(\.stringValue)
      guard texts.count == names.count, texts.allSatisfy(schema.declaresMark) else { return nil }
      marks = texts.map(ExactString.init(_:))
      guard Set(marks).count == marks.count else { return nil }
    default: return nil
    }
    let pointer = FieldState(value: .string(revision), clock: change.clock, rule: .register)
    return .revisioned(
      RevisionedState(
        fields: [:], head: becomesHead ? pointer : nil, marks: Dictionary(uniqueKeysWithValues: marks.map { ($0, pointer) }), revisions: [ExactString(revision): item]))
  }
}

extension ChangeRecord {
  func restricted(to fields: [String: JSONValue]) -> ChangeRecord {
    ChangeRecord(id: id, clock: clock, schema: schema, entity: entity, key: key, kind: kind, fields: fields)
  }
}
