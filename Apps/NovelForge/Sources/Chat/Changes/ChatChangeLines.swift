import Foundation
import NovelForgeCore

/// One index of an applied change as the history lists it: a content change or an action, with the rewrites that carry it.
nonisolated struct ChatChangeLine: Equatable, Identifiable, Sendable {
  let index: Int
  let subject: String
  let state: ProposalChangeEntryState
  let isAction: Bool
  /// The subjects of the rewrites that may have carried it: one is its leader; several mean which one did is not known.
  let carriers: [String]

  var id: Int { index }
}

/// What the history shows of an applied change (chat.tsx:104-127, with each change's own state as progress-panel-view.ts:272-296 reads it).
nonisolated enum ChatChangeLines {
  struct Entry: Equatable, Sendable {
    let index: Int
    let state: ProposalChangeEntryState
    let isAction: Bool
    let carriers: [Int]
  }

  static func lines(of change: ChatChange) -> [ChatChangeLine] {
    let entries = change.entries.map { Entry(index: $0.index, state: $0.state, isAction: $0.isAction, carriers: $0.carriers) }
    return lines(entries, ops: change.record.map { ChatOp.ops(of: $0.card) } ?? [])
  }

  /// Changes the first applier left out were never applied, so only what it selected is listed.
  static func lines(_ entries: [Entry], ops: [ChatOp]) -> [ChatChangeLine] {
    entries.filter { $0.state != .declined && $0.state != .notApplied }.map { entry in
      ChatChangeLine(
        index: entry.index, subject: subject(entry.index, ops: ops), state: entry.state, isAction: entry.isAction,
        carriers: entry.carriers.map { subject($0, ops: ops) })
    }
  }

  /// chat.tsx:113: the card's summary, else the records it touched, else what is left: the actions it ran.
  static func summary(of change: ChatChange) -> String {
    guard let record = change.record else { return String(localized: "A change this version cannot read", table: "ChatChanges") }
    let summary = record.card.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !summary.isEmpty { return summary }
    let refs = change.refs
    return refs.isEmpty ? String(localized: "pipeline actions", table: "ChatChanges") : refs.joined(separator: ", ")
  }

  private static func subject(_ index: Int, ops: [ChatOp]) -> String {
    ops.first { $0.index == index }?.subject ?? String(localized: "Change \(index + 1)", table: "ChatChanges")
  }
}
