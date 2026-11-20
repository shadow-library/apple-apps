import ShadowText

enum FinalizeEditRefusal: Equatable, Sendable {
  case nothingToEdit
  case nothingChanged
  case notEditable(field: String)
  case wrongShape(field: String)

  var reason: String {
    switch self {
    case .nothingToEdit: "an appearance has nothing to edit — keep or skip it"
    case .nothingChanged: "nothing was changed"
    case .notEditable(let field): "\(field) cannot be edited here"
    case .wrongShape(let field): "\(field) has the wrong shape"
    }
  }
}

private struct EditableField<Record>: Sendable {
  let name: String
  let accepts: @Sendable (OrderedJSON) -> Bool
  let apply: @Sendable (inout Record, OrderedJSON) -> Void
}

private func isText(_ value: OrderedJSON) -> Bool {
  if case .null = value { return true }
  return value.stringValue != nil
}

private func isFlag(_ value: OrderedJSON) -> Bool {
  if case .bool = value { return true }
  return false
}

private func isList(_ value: OrderedJSON) -> Bool {
  if case .null = value { return true }
  return value.arrayValue?.allSatisfy { $0.stringValue != nil } ?? false
}

private func isFilled(_ value: OrderedJSON) -> Bool {
  guard let text = value.stringValue else { return false }
  return !text.jsTrim().isEmpty
}

private func isOneOf(_ allowed: [String]) -> @Sendable (OrderedJSON) -> Bool {
  { value in value.stringValue.map { text in allowed.contains { $0.jsEquals(text) } } ?? false }
}

private func flag(_ value: OrderedJSON) -> Bool {
  if case .bool(let flag) = value { return flag }
  return false
}

private func list(_ value: OrderedJSON) -> [String]? {
  value.arrayValue?.compactMap(\.stringValue)
}

private func text<Record>(_ name: String, _ field: any WritableKeyPath<Record, String?> & Sendable) -> EditableField<Record> {
  EditableField(name: name, accepts: isText) { $0[keyPath: field] = $1.stringValue }
}

private func filled<Record>(_ name: String, _ field: any WritableKeyPath<Record, String> & Sendable) -> EditableField<Record> {
  EditableField(name: name, accepts: isFilled) { record, value in value.stringValue.map { record[keyPath: field] = $0 } }
}

private func openFlag<Record>(_ field: any WritableKeyPath<Record, Bool?> & Sendable) -> EditableField<Record> {
  EditableField(name: "intentionallyOpen", accepts: isFlag) { $0[keyPath: field] = flag($1) }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:382
private let entityFields: [EditableField<ProposedChange.Entity>] = [filled("name", \.name), text("notes", \.notes)]

private let stateFields: [EditableField<ProposedChange.CharacterState>] = [
  text("location", \.location), EditableField(name: "conditions", accepts: isList) { $0.conditions = list($1) }, text("immediateGoal", \.immediateGoal),
  text("statusNote", \.statusNote),
]

private let relationshipFields: [EditableField<ProposedChange.Relationship>] = [text("note", \.note)]

private let threadFields: [EditableField<ProposedChange.PlotThread>] = [
  EditableField(name: "status", accepts: isOneOf(["open", "closed"])) { record, value in
    value.stringValue.flatMap(ThreadStatus.init(rawValue:)).map { record.status = $0 }
  },
  text("summary", \.summary), openFlag(\.intentionallyOpen),
]

private let mysteryFields: [EditableField<ProposedChange.Mystery>] = [
  EditableField(name: "status", accepts: isOneOf(["open", "resolved"])) { record, value in
    value.stringValue.flatMap(MysteryStatus.init(rawValue:)).map { record.status = $0 }
  },
  text("question", \.question), openFlag(\.intentionallyOpen),
]

private let knowledgeFields: [EditableField<ProposedChange.Knowledge>] = [filled("how", \.how)]

private let milestoneFields: [EditableField<ProposedChange.Milestone>] = [EditableField(name: "reached", accepts: isFlag) { $0.reached = flag($1) }]

private let summaryFields: [EditableField<String>] = [filled("text", \.self)]

private func edit<Record>(_ record: Record, _ patch: OrderedJSONObject, _ fields: [EditableField<Record>]) throws(FinalizeReviewError) -> Record {
  if patch.entries.isEmpty { throw .editRefused(.nothingChanged) }
  var edits: [(field: EditableField<Record>, value: OrderedJSON)] = []
  for entry in patch.entries {
    guard let field = fields.first(where: { $0.name.jsEquals(entry.key) }) else { throw .editRefused(.notEditable(field: entry.key)) }
    guard field.accepts(entry.value) else { throw .editRefused(.wrongShape(field: entry.key)) }
    edits.append((field, entry.value))
  }
  var edited = record
  for (field, value) in edits { field.apply(&edited, value) }
  return edited
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:413; a field named after an `Object.prototype` member is refused, which the reference accepts.
func editedChange(_ proposed: ProposedChange, _ patch: OrderedJSONObject) throws(FinalizeReviewError) -> ProposedChange {
  switch proposed {
  case .entity(let entity): .entity(try edit(entity, patch, entityFields))
  case .appearance: throw .editRefused(.nothingToEdit)
  case .characterState(let state): .characterState(try edit(state, patch, stateFields))
  case .relationship(let relationship): .relationship(try edit(relationship, patch, relationshipFields))
  case .thread(let thread): .thread(try edit(thread, patch, threadFields))
  case .mystery(let mystery): .mystery(try edit(mystery, patch, mysteryFields))
  case .knowledge(let knowledge): .knowledge(try edit(knowledge, patch, knowledgeFields))
  case .milestone(let milestone): .milestone(try edit(milestone, patch, milestoneFields))
  case .summary(let text): .summary(text: try edit(text, patch, summaryFields))
  }
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:431
func effectiveChange(_ item: FinalizeReviewItem) -> ProposedChange {
  item.decision == .edited ? item.edited ?? item.proposed : item.proposed
}

// apps/novel-forge-server/src/modules/finalize-review/finalize-review-items.ts:436
func openItems(_ items: [FinalizeReviewItem]) -> [FinalizeReviewItem] {
  items.filter { $0.decision == nil }
}
