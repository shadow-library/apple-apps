import Foundation
import NovelForgeCore
import ShadowCore

/// One stored operation of a card as the chat reads it, from the vault's stored form; an operation this version no longer validates keeps its index.
nonisolated struct ChatOp: Equatable, Sendable {
  let index: Int
  let fields: [String: JSONValue]
  let isReadable: Bool

  init(index: Int, stored: JSONValue, problems: [String]) {
    self.index = index
    fields = stored.objectValue ?? [:]
    isReadable = problems.isEmpty && !fields.isEmpty
  }

  static func ops(of card: ProposalCard) -> [ChatOp] {
    card.changeSet.enumerated().map { ChatOp(index: $0.offset, stored: $0.element.stored, problems: $0.element.problems) }
  }

  var type: String { fields["op"]?.stringValue ?? "" }

  var isAction: Bool { type.hasPrefix("action.") }

  // apps/novel-forge-web/src/lib/proposals.ts:5-9: applied only when the author selects them deliberately, so they start unselected
  var isGuarded: Bool { Self.guarded.contains(type) }

  /// An action with no executor in ProposalActionRegistry yet: it starts work the chapters section brings.
  var isJobAction: Bool { isAction && !Self.runnable.contains(type) }

  var isPassageRewrite: Bool { type == "draft.rewrite_passage" }

  /// What names the record an operation writes, so two replies' operations on the same record are recognised as one.
  var identity: [String: JSONValue] {
    fields.filter { Self.identifying.contains($0.key) }
  }

  // apps/novel-forge-web/src/features/chat/chat-view.ts:74-86
  var subject: String {
    if !isReadable { return String(localized: "A change this version cannot read", table: "ChatCards") }
    let (chapter, volume) = (scalar("chapter"), scalar("volumeKey"))
    switch type {
    case "premise.update": return storySubject
    case "draft.rewrite_passage": return rewriteSubject
    case "organise.rule": return String(localized: "Rule", table: "ChatCards")
    case "volume.upsert": return text("title") ?? String(localized: "Volume \(volume)", table: "ChatCards")
    case "milestone.upsert": return text("label") ?? scalar("milestoneKey")
    case let promise where promise.hasPrefix("promise."): return text("label") ?? (fields["key"].map { _ in scalar("key") } ?? type)
    case "brief.update": return text("title") ?? String(localized: "Chapter \(chapter)", table: "ChatCards")
    case "bible_document.upsert":
      return fields["frontmatter"]?["title"]?.stringValue.flatMap(Self.trimmed) ?? scalar("slug").replacing("-", with: " ").replacing("_", with: " ")
    case let action where action.hasPrefix("action."): return actionSubject
    default: return text("name") ?? fields["entityKey"].map { _ in scalar("entityKey") } ?? fields["factKey"].map { _ in scalar("factKey") } ?? type
    }
  }

  /// chat-view.ts:165-167: the words a passage rewrite takes out and puts in.
  var passageDiff: (removed: String, added: String) {
    (scalar("passage").trimmingCharacters(in: .whitespacesAndNewlines), scalar("replacement").trimmingCharacters(in: .whitespacesAndNewlines))
  }

  /// chat-view.ts:152-157: a card whose every change rewrites passages of one chapter names that chapter.
  static func title(of ops: [ChatOp]) -> String {
    let chapters = Set(ops.map { $0.isPassageRewrite ? $0.scalar("chapter") : nil })
    if chapters.count == 1, let chapter = chapters.first ?? nil { return String(localized: "\(ops.count) changes to chapter \(chapter)", table: "ChatCards") }
    return String(localized: "\(ops.count) changes", table: "ChatCards")
  }

  func scalar(_ key: String) -> String {
    switch fields[key] {
    case .string(let value)?: value
    case .int(let value)?: String(value)
    case .bool(let value)?: String(value)
    default: ""
    }
  }

  private func text(_ key: String) -> String? {
    fields[key]?.stringValue.flatMap(Self.trimmed)
  }

  // chat-view.ts:50-54: "Premise" stands for the premise, brief, themes and instructions together
  private var storySubject: String {
    let named = Self.storyFields.compactMap { fields[$0.key] == nil ? nil : String(localized: $0.label) }
    let premise = Self.premiseFields.contains { fields[$0] != nil } || named.isEmpty
    return ((premise ? [String(localized: "Premise", table: "ChatCards")] : []) + named).joined(separator: ", ")
  }

  // chat-view.ts:61-72
  private var rewriteSubject: String {
    let chapter = scalar("chapter")
    let label = text("label")
    guard let paragraph = fields["anchor"]?["paragraph"]?.intValue else {
      guard let label else { return String(localized: "A passage of chapter \(chapter)", table: "ChatCards") }
      return String(localized: "Chapter \(chapter) · \(label)", table: "ChatCards")
    }
    guard let label else { return String(localized: "¶\(paragraph) of chapter \(chapter)", table: "ChatCards") }
    return "¶\(paragraph) · \(label)"
  }

  // chat-view.ts:88-118
  private var actionSubject: String {
    let chapter = scalar("chapter")
    switch type {
    case "action.generate_chapter": return String(localized: "Write chapter \(chapter)", table: "ChatCards")
    case "action.plan_chapter": return String(localized: "Plan the next chapter", table: "ChatCards")
    case "action.revise_draft": return String(localized: "Revise chapter \(chapter)", table: "ChatCards")
    case "action.judge_draft": return String(localized: "Check chapter \(chapter) against the Story Bible", table: "ChatCards")
    case "action.approve_draft": return String(localized: "Approve chapter \(chapter)", table: "ChatCards")
    case "action.finalize":
      guard let upTo = fields["upTo"]?.intValue else { return String(localized: "Finalize the approved chapters", table: "ChatCards") }
      return String(localized: "Finalize chapters up to \(upTo)", table: "ChatCards")
    case "action.apply_continuity": return String(localized: "Add chapter \(chapter) to the Story Bible", table: "ChatCards")
    case "action.validate":
      guard fields["chapter"]?.intValue != nil else { return String(localized: "Check the novel for continuity", table: "ChatCards") }
      return String(localized: "Check chapter \(chapter) for continuity", table: "ChatCards")
    case "action.organise_notes": return String(localized: "Organise your notes", table: "ChatCards")
    case "action.audit_bible": return String(localized: "Audit the Story Bible", table: "ChatCards")
    case "action.enhance_premise": return String(localized: "Strengthen the premise", table: "ChatCards")
    case "action.advance_volume": return String(localized: "Mark this volume's goal met and start the next", table: "ChatCards")
    default: return String(localized: "Run an action", table: "ChatCards")
    }
  }

  private static func trimmed(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static let guarded: Set<String> = ["action.finalize", "action.approve_draft", "action.apply_continuity", "action.generate_chapter"]
  private static let runnable: Set<String> = ["action.approve_draft", "action.finalize", "action.advance_volume"]
  private static let identifying: Set<String> = ["op", "entityKey", "factKey", "section", "slug", "key", "kind", "volumeKey", "milestoneKey", "chapter", "upTo"]
  // chat-view.ts:35-43
  private static let premiseFields = ["premise", "brief", "themes", "instructions"]
  private static let storyFields: [(key: String, label: LocalizedStringResource)] = [
    ("theme", LocalizedStringResource("Theme", table: "ChatCards")), ("readerPromise", LocalizedStringResource("Reader promise", table: "ChatCards")),
    ("protagonistKey", LocalizedStringResource("Protagonist", table: "ChatCards")), ("opposition", LocalizedStringResource("Opposition", table: "ChatCards")),
    ("endingQuestion", LocalizedStringResource("Ending question", table: "ChatCards")), ("ending", LocalizedStringResource("Ending", table: "ChatCards")),
  ]
}

/// apps/novel-forge-web/src/features/proposals/ChangeOpBody.tsx:10-37: scalar fields as a key and value grid, prose fields as Markdown.
nonisolated struct ChatOpBody: Equatable, Sendable {
  struct Field: Equatable, Sendable {
    let key: String
    let value: String
  }

  let rationale: String?
  let inline: [Field]
  let prose: [Field]

  init(_ op: ChatOp) {
    let rationale = op.fields["rationale"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.rationale = rationale.isEmpty ? nil : rationale
    let entries = op.fields.filter { $0.key != "op" && $0.key != "rationale" }.sorted { $0.key < $1.key }
    let isProse: (String, JSONValue) -> Bool = { key, value in
      Self.proseFields.contains(key) && !(value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    prose = entries.filter { isProse($0.key, $0.value) }.map { Field(key: $0.key, value: $0.value.stringValue ?? "") }
    inline = entries.filter { !isProse($0.key, $0.value) }.map { Field(key: $0.key, value: Self.format($0.value)) }
  }

  // ChangeOpBody.tsx:33-37
  static func format(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let flag): String(flag)
    case .int(let number): String(number)
    case .string(let text): text
    case .array(let items): items.map { item in item.objectValue == nil && item.arrayValue == nil ? format(item) : json(item) }.joined(separator: ", ")
    case .object: json(value)
    }
  }

  private static func json(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  // ChangeOpBody.tsx:11-31
  private static let proseFields: Set<String> = [
    "body", "premise", "brief", "objective", "escalation", "payoff", "hook", "conflict", "motivation", "notes", "summary", "chapterSummary", "instructions", "note",
    "opposition", "theme", "readerPromise", "endingQuestion", "ending",
  ]
}
