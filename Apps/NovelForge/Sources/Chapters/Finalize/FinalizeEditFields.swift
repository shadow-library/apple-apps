import Foundation
import NovelForgeCore
import ShadowCore
import ShadowText

/// apps/novel-forge-web/src/lib/finalize-review.ts:84-110, 209-282: the fields `editedChange` accepts per proposed record, never those naming the record, and
/// the patch an edit sends.
enum FinalizeEditFields {
  struct Field: Equatable {
    enum Kind: Equatable {
      case text
      case longText
      case list
      case flag
      case choice([String])
    }

    let key: String
    let label: String
    let kind: Kind
    var required = false
  }

  enum Value: Equatable {
    case text(String)
    case flag(Bool)
  }

  enum Patch: Equatable {
    case patch([String: JSONValue])
    case problem(String)
  }

  // finalize-review.ts:209-226
  static func record(of change: [String: JSONValue]) -> (name: String, fields: [String: JSONValue]) {
    switch change["category"]?.stringValue {
    case "entity": ("entity", change["entity"]?.objectValue ?? [:])
    case "character_state": ("state", change["state"]?.objectValue ?? [:])
    case "relationship": ("relationship", change["relationship"]?.objectValue ?? [:])
    case "promise": change["thread"] != nil ? ("thread", change["thread"]?.objectValue ?? [:]) : ("mystery", change["mystery"]?.objectValue ?? [:])
    case "knowledge": ("knowledge", change)
    case "milestone": ("milestone", change)
    case "summary": ("summary", change)
    default: ("appearance", [:])
    }
  }

  static func fields(of change: [String: JSONValue]) -> [Field] {
    switch record(of: change).name {
    case "entity":
      [
        Field(key: "name", label: String(localized: "Name", table: "Finalize"), kind: .text, required: true),
        Field(key: "notes", label: String(localized: "Notes", table: "Finalize"), kind: .longText),
      ]
    case "state":
      [
        Field(key: "location", label: String(localized: "Where they are", table: "Finalize"), kind: .text),
        Field(key: "conditions", label: String(localized: "Conditions (comma separated)", table: "Finalize"), kind: .list),
        Field(key: "immediateGoal", label: String(localized: "What they want next", table: "Finalize"), kind: .text),
        Field(key: "statusNote", label: String(localized: "How they are", table: "Finalize"), kind: .longText),
      ]
    case "relationship": [Field(key: "note", label: String(localized: "Note", table: "Finalize"), kind: .longText)]
    case "thread":
      [
        Field(key: "status", label: String(localized: "Status", table: "Finalize"), kind: .choice(["open", "closed"])),
        Field(key: "summary", label: String(localized: "The promise", table: "Finalize"), kind: .longText),
        Field(key: "intentionallyOpen", label: String(localized: "Left open on purpose", table: "Finalize"), kind: .flag),
      ]
    case "mystery":
      [
        Field(key: "status", label: String(localized: "Status", table: "Finalize"), kind: .choice(["open", "resolved"])),
        Field(key: "question", label: String(localized: "The question", table: "Finalize"), kind: .longText),
        Field(key: "intentionallyOpen", label: String(localized: "Left open on purpose", table: "Finalize"), kind: .flag),
      ]
    case "knowledge": [Field(key: "how", label: String(localized: "How they learn it", table: "Finalize"), kind: .longText, required: true)]
    case "milestone": [Field(key: "reached", label: String(localized: "Reached in this chapter", table: "Finalize"), kind: .flag)]
    case "summary": [Field(key: "text", label: String(localized: "What later chapters read", table: "Finalize"), kind: .longText, required: true)]
    default: []
    }
  }

  static func isEditable(_ item: FinalizeReviewScreen.Item) -> Bool {
    item.category != nil && !fields(of: item.proposed).isEmpty
  }

  // finalize-review.ts:240-244
  static func value(_ field: Field, _ raw: JSONValue?) -> Value {
    switch field.kind {
    case .flag: .flag(raw?.boolValue == true)
    case .list: .text(raw?.arrayValue?.compactMap(\.stringValue).joined(separator: ", ") ?? "")
    case .text, .longText, .choice: .text(raw?.stringValue ?? "")
    }
  }

  /// finalize-review.ts:246-251: the form starts from what finalize would apply, the author's earlier edit when there is one.
  static func values(_ item: FinalizeReviewScreen.Item) -> [String: Value] {
    let source = item.decision == .edited ? item.edited ?? item.proposed : item.proposed
    let fields = record(of: source).fields
    return Dictionary(uniqueKeysWithValues: Self.fields(of: item.proposed).map { ($0.key, value($0, fields[$0.key])) })
  }

  // finalize-review.ts:253-265
  static func patchValue(_ field: Field, _ value: Value) -> JSONValue {
    if case .flag(let on) = value { return .bool(on) }
    guard case .text(let raw) = value else { return .null }
    let text = raw.jsTrim()
    switch field.kind {
    case .list:
      let entries = text.split(separator: ",").map { String($0).jsTrim() }.filter { !$0.isEmpty }
      return entries.isEmpty ? .null : .array(entries.map(JSONValue.string))
    case .choice: return .string(text)
    case .flag: return .bool(false)
    case .text, .longText: return text.isEmpty ? .null : .string(text)
    }
  }

  /// finalize-review.ts:267-282: every field that differs from the proposal, as the core lays the patch over `proposed`, so a second edit carries the first's.
  static func patch(_ item: FinalizeReviewScreen.Item, values: [String: Value]) -> Patch {
    let proposed = record(of: item.proposed).fields
    var patch = [String: JSONValue]()
    for field in fields(of: item.proposed) {
      let original = value(field, proposed[field.key])
      let current = values[field.key] ?? original
      if field.required, case .text(let text) = current, text.jsTrim().isEmpty {
        return .problem(String(localized: "\(field.label) can't be empty.", table: "Finalize"))
      }
      let next = patchValue(field, current)
      if next == patchValue(field, original) { continue }
      patch[field.key] = next
    }
    if patch.isEmpty { return .problem(String(localized: "This is what was proposed. Choose Keep to record it as it is.", table: "Finalize")) }
    return .patch(patch)
  }
}
