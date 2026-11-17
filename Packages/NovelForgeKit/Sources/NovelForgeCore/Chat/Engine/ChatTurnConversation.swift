import Foundation

/// The conversation a turn sends (apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:35-39): `plain` is the summary and each stored
/// message as written, which the history budget reads; `history` is what is sent, the open segment's turns as this device sent them when one continues.
struct ChatTurnConversation: Equatable, Sendable {
  struct Segment: Equatable, Sendable {
    let id: String
    let stableContext: String
    let sections: ChatHeldSections
  }

  // chat-compaction.service.ts:30
  static let maxSegmentTokens = 24_000

  let plain: [PromptMessage]
  let history: [PromptMessage]
  let segment: Segment?

  /// `messages` are the window's messages the turn's history holds, oldest first. A keyed turn continues the latest reply's segment when this device
  /// recorded it, the window has not been folded since and the playbook is the same, unless replaying it would run past `maxSegmentTokens`
  /// (chat-compaction.service.ts:80-88); any other turn sends the plain window, a standard one with placeholders for unrestricted text (:74-77).
  static func build(
    _ window: ChatConversationWindow, messages: [ChatWindowMessage], mode: ContentMode, keyed: Bool, playbook: String, exchanges: [UUID: ChatExchange]
  ) -> ChatTurnConversation {
    let opening = window.opening(for: mode)
    let plain = opening + messages.flatMap { window.render($0, for: mode) }
    guard keyed else { return ChatTurnConversation(plain: plain, history: plain, segment: nil) }
    let rows = messages.map { message in
      ChatExchangeRow(
        role: message.role, turn: message.role == .user ? message.record.id : message.record.answers,
        exchange: message.role == .assistant ? exchanges[message.record.id] : nil, message: message)
    }
    guard let held = ChatContextExchange.heldSegment(rows, through: window.watermark, playbook: playbook) else {
      return ChatTurnConversation(plain: plain, history: plain, segment: nil)
    }
    let history = opening + ChatContextExchange.replayWindow(rows, segment: held.id) { window.render($0.message, for: mode) }
    guard tokens(history) <= maxSegmentTokens else { return ChatTurnConversation(plain: plain, history: plain, segment: nil) }
    return ChatTurnConversation(plain: plain, history: history, segment: Segment(id: held.id, stableContext: held.stableContext, sections: held.sections))
  }

  // chat-compaction.service.ts:56
  static func tokens(_ messages: [PromptMessage]) -> Int {
    messages.reduce(0) { $0 + countTokens($1.text) }
  }
}
