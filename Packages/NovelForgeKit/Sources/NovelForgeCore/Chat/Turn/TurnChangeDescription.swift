// apps/novel-forge-server/src/modules/refinement/chat-turn-emitter.ts:34
private let maximumLabelLength = 120

// chat-turn-emitter.ts:36; looked up as an own key, where the reference also reads `Object.prototype` (a `type` of "constructor" is not a group).
private let entityGroups: [JSString: TurnChangeGroup] = ["character": .people, "faction": .people, "location": .places, "power_rule": .power]

// chat-turn-emitter.ts:51
private let premiseFields = ["premise", "brief", "themes", "instructions"]

// chat-turn-emitter.ts:52
private let storyFieldLabels: [(field: String, name: String)] = [
  ("theme", "Theme"), ("readerPromise", "Reader promise"), ("protagonistKey", "Protagonist"), ("opposition", "Opposition"),
  ("endingQuestion", "Ending question"), ("ending", "Ending"),
]

// chat-turn-emitter.ts:82
private let whitespaceRun = builtInPattern(#"\s+"#, flags: "g")

// chat-turn-emitter.ts:76
private let slugSeparator = builtInPattern("[-_]", flags: "g")

/// Titles a change the way the web titles its cards, so the progress list and the settled turn name a change alike (chat-turn-emitter.ts:97).
func describeStreamedChange(index: Int, element: ChangeSetElement) -> TurnChangeEvent {
  let fields = (try? OrderedJSON(parsing: element.source))?.objectValue
  return TurnChangeEvent(index: index, op: element.op, label: label(op: element.op, fields: fields), group: group(op: element.op, fields: fields))
}

// chat-turn-emitter.ts:43
private func text(_ value: OrderedJSON?) -> String? {
  guard case .string(let raw)? = value else { return nil }
  let trimmed = raw.jsTrim()
  return trimmed.isEmpty ? nil : trimmed
}

// chat-turn-emitter.ts:47
private func key(_ value: OrderedJSON?) -> String? {
  switch value {
  case .int(let number)?: Double(number).jsString
  case .double(let number)?: number.jsString
  default: text(value)
  }
}

// chat-turn-emitter.ts:62
private func storySubject(_ fields: OrderedJSONObject) -> String {
  let named = storyFieldLabels.filter { fields[$0.field] != nil }.map(\.name)
  let premise = premiseFields.contains { fields[$0] != nil } || named.isEmpty
  return ((premise ? ["Premise"] : []) + named).joined(separator: ", ")
}

// chat-turn-emitter.ts:68
private func subject(op: String, fields: OrderedJSONObject) -> String? {
  if op.jsEquals("premise.update") { return storySubject(fields) }
  if op.jsEquals("organise.rule") { return "Rule" }
  if op.jsEquals("action.plan_chapter") { return "Plan the next chapter" }
  if op.jsEquals("action.organise_notes") { return "Organise your notes" }
  if op.jsStartsWith("volume.") { return text(fields["title"]) ?? "Volume \(key(fields["volumeKey"]) ?? "")" }
  if op.jsStartsWith("milestone.") { return text(fields["label"]) ?? key(fields["milestoneKey"]) }
  if op.jsStartsWith("promise.") { return text(fields["label"]) ?? key(fields["key"]) }
  if op.jsStartsWith("brief.") || op.jsStartsWith("draft.") { return text(fields["title"]) ?? "Chapter \(key(fields["chapter"]) ?? "")" }
  if op.jsStartsWith("bible_document.") {
    return text(fields["frontmatter"]?.objectValue?["title"]) ?? key(fields["slug"]).map { $0.jsReplace(slugSeparator, " ") }
  }
  return text(fields["name"]) ?? key(fields["entityKey"]) ?? key(fields["factKey"])
}

// chat-turn-emitter.ts:81
private func label(op: String, fields: OrderedJSONObject?) -> String {
  let subject = fields.flatMap { subject(op: op, fields: $0) } ?? op
  let collapsed = subject.jsReplace(whitespaceRun, " ").jsTrim()
  let value = collapsed.isEmpty ? op : collapsed
  guard value.jsLength > maximumLabelLength else { return value }
  return String(decoding: value.jsSliceCodeUnits(0, maximumLabelLength - 1), as: UTF16.self) + "…"
}

// chat-turn-emitter.ts:86
private func group(op: String, fields: OrderedJSONObject?) -> TurnChangeGroup {
  if op.jsEquals("premise.update") { return .premise }
  if op.jsStartsWith("bible_document.") { return .pages }
  if op.jsStartsWith("promise.") { return .threads }
  if op.jsEquals("entity.upsert"), case .string(let type)? = fields?["type"] { return entityGroups[JSString(type)] ?? .other }
  return .other
}
