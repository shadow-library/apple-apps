import Foundation
import ShadowCore
import ShadowText

// apps/novel-forge-server/src/database/schemas/refinement.ts:105
struct ChatHeldSection: Equatable, Sendable {
  let digest: String
  let heading: String
}

/// The sections a conversation holds, by key in the order they were sent.
struct ChatHeldSections: Equatable, Sendable {
  private(set) var entries: [(key: String, section: ChatHeldSection)] = []

  init(_ entries: [(key: String, section: ChatHeldSection)] = []) {
    for entry in entries { self[entry.key] = entry.section }
  }

  subscript(key: String) -> ChatHeldSection? {
    get { entries.first { $0.key.jsEquals(key) }?.section }
    set {
      guard let position = entries.firstIndex(where: { $0.key.jsEquals(key) }) else {
        if let newValue { entries.append((key, newValue)) }
        return
      }
      if let newValue { entries[position].section = newValue } else { entries.remove(at: position) }
    }
  }

  static func == (left: ChatHeldSections, right: ChatHeldSections) -> Bool {
    left.entries.count == right.entries.count && zip(left.entries, right.entries).allSatisfy { $0.key.jsEquals($1.key) && $0.section == $1.section }
  }
}

// refinement.ts:111
struct ChatSegmentOpening: Equatable, Sendable {
  /// The compaction watermark when the segment opened, as the window's owner writes it; a different one ends the segment.
  let through: String
  let playbook: String
  let stableContext: String
}

// refinement.ts:123: what one reply's turn sent, so the next turn on this device sends it again unchanged and only appends
struct ChatExchange: Equatable, Sendable {
  let segment: String
  let opening: ChatSegmentOpening?
  let sections: ChatHeldSections
  /// The turn's own message, then each further call's reply and follow-up, in order; the final reply is the message's content.
  let messages: [PromptMessage]
}

// apps/novel-forge-server/src/modules/refinement/chat-exchange.ts:15
struct ChatContextUpdate: Equatable, Sendable {
  let text: String
  let sections: ChatHeldSections
}

/// A message of the session's window as the exchange pairs them: `turn` names the author's message, its own id on the author's row and the one it answers on a reply.
struct ChatExchangeRow<Message: Sendable>: Sendable {
  let role: ChatRole
  let turn: UUID?
  let exchange: ChatExchange?
  let message: Message
}

enum ChatContextExchange {
  // chat-exchange.ts:22-25
  static let unchanged = "Unchanged since the previous turn."
  static let changed = "Changed since the previous turn — each section below replaces the one of the same name earlier in this conversation:"
  static let gone = "Nothing now."
  static let leftOut = "Left out this turn for space — the earlier version may be out of date; look it up if you need it."
  /// Native: the reference has no wording for a section that could not be read; it is neither left out for space nor gone.
  static let unreadable = "Could not be read on this device this turn — the earlier version may be out of date; do not rely on it."

  // chat-exchange.ts:31
  static func playbookDigest(_ scopeInstructions: String) -> String {
    sha256Hex(scopeInstructions)
  }

  // chat-exchange.ts:35
  static func held(_ section: ChatPackSection) -> ChatHeldSection {
    let lineEnd = section.rendered.jsIndexOf("\n")
    return ChatHeldSection(digest: sha256Hex(section.rendered), heading: lineEnd == -1 ? section.rendered : section.rendered.jsSlice(0, lineEnd))
  }

  /// The opening turn sends the whole volatile context, later turns only changed sections; a section the budget left out is flagged stale and sent whole on return.
  // chat-exchange.ts:40
  static func contextUpdate(_ pack: ChatContextPack, holding: ChatHeldSections?) -> ChatContextUpdate {
    var sections = ChatHeldSections()
    for section in pack.sections { sections[section.key] = held(section) }
    guard let holding else { return ChatContextUpdate(text: pack.renderedVolatile.isEmpty ? "nothing" : pack.renderedVolatile, sections: sections) }
    let changed = pack.sections.filter { holding[$0.key]?.digest != sections[$0.key]?.digest }.map(\.rendered)
    let dropped = holding.entries.filter { sections[$0.key] == nil }.map { entry in "\(entry.section.heading)\n\n\(absence(of: entry.key, in: pack.omitted))" }
    if changed.isEmpty && dropped.isEmpty { return ChatContextUpdate(text: unchanged, sections: sections) }
    return ChatContextUpdate(text: "\(Self.changed)\n\n\((changed + dropped).joined(separator: "\n\n---\n\n"))", sections: sections)
  }

  private static func absence(of key: String, in omitted: [ChatPackOmission]) -> String {
    let reasons = omitted.filter { $0.key.jsEquals(key) }.map(\.reason)
    if reasons.contains(.unresolved) { return unreadable }
    return reasons.isEmpty ? gone : leftOut
  }

  /// The segment the latest reply belongs to while it can be continued: no compaction since, the same playbook, and the reply has an exchange on this device.
  // chat-exchange.ts:59
  static func heldSegment<Message>(_ rows: [ChatExchangeRow<Message>], through: String, playbook: String) -> (id: String, stableContext: String, sections: ChatHeldSections)? {
    guard let latest = rows.last(where: { $0.role == .assistant })?.exchange else { return nil }
    let opening = rows.first { $0.exchange.map { $0.segment.jsEquals(latest.segment) && $0.opening != nil } ?? false }?.exchange?.opening
    guard let opening, opening.through.jsEquals(through), opening.playbook.jsEquals(playbook) else { return nil }
    return (latest.segment, opening.stableContext, latest.sections)
  }

  /// The window as the segment's turns sent it; a turn's own message carries the author's, so the author's row is not sent again.
  // chat-exchange.ts:68
  static func replayWindow<Message>(_ rows: [ChatExchangeRow<Message>], segment: String, render: (ChatExchangeRow<Message>) -> [PromptMessage]) -> [PromptMessage] {
    let replayed = Set(rows.compactMap { row in row.role == .assistant && row.exchange?.segment.jsEquals(segment) == true ? row.turn : nil })
    return rows.flatMap { row -> [PromptMessage] in
      if row.role == .user { return row.turn.map(replayed.contains) == true ? [] : render(row) }
      guard let exchange = row.exchange, exchange.segment.jsEquals(segment) else { return render(row) }
      return exchange.messages + render(row)
    }
  }
}
