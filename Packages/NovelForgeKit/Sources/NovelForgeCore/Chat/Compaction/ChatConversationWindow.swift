import Foundation
import ShadowStore
import ShadowText

// apps/novel-forge-server/src/modules/refinement/chat-compaction.service.ts:32-33
let unrestrictedReplyPlaceholder = "[reply written with the unrestricted model — omitted]"
let unrestrictedSummaryPlaceholder = "[earlier conversation summarised with the unrestricted model — omitted]"

struct ChatWindowMessage: Equatable, Sendable {
  let role: ChatRole
  let record: ChatMessageRecord
  /// An unknown mode counts, and so does a reply that recorded none (ChatMessageRow.claimsUnrestricted).
  let claimsUnrestricted: Bool

  /// The reference holds every reply's text in the history, refused or not; an author's message it cannot screen counts as refused.
  // chat-compaction.service.ts:206-208
  var refusesAuthored: Bool {
    record.hasUnreadableContexts || findHardLine(turnScreens(record.content, contexts: record.passageContexts).map(\.text)) != nil
  }

  var tokens: Int { record.tokens ?? countTokens(record.content) }
}

enum ChatLockState: Equatable, Sendable {
  case unlocked
  case locked
  /// A fault somewhere in the vault's chat rows hides whether the session holds unrestricted text.
  case unavailable
}

/// The conversation a turn sends (chat-compaction.service.ts:90-110): the standing summary and every message it does not cover, oldest first. A message
/// that cannot be read, or whose role this version does not know, stays outside the window until it can be read, so it is neither folded nor counted.
struct ChatConversationWindow: Equatable, Sendable {
  let session: UUID
  let summary: AppendedEntry<ChatSummaryRecord>?
  let messages: [ChatWindowMessage]
  let lock: ChatLockState

  init(session: UUID, summary: AppendedEntry<ChatSummaryRecord>?, messages: [ChatWindowMessage], lock: ChatLockState) {
    self.session = session
    self.summary = summary
    self.messages = messages
    self.lock = lock
  }

  init(session: UUID, contents: ChatWindowContents?, lock: Derived<ChatUnrestrictedLock?>) {
    let messages = (contents?.messages ?? []).compactMap { message -> ChatWindowMessage? in
      guard let record = message.record, let role = record.role.known else { return nil }
      return ChatWindowMessage(role: role, record: record, claimsUnrestricted: message.row.claimsUnrestricted)
    }
    let state: ChatLockState =
      switch lock {
      case .available(nil): .unlocked
      case .available: .locked
      case .unavailable: .unavailable
      }
    self.init(session: session, summary: contents?.summary, messages: messages, lock: state)
  }

  /// What a segment opened on this window records as `ChatSegmentOpening.through`; a fold, here or arriving by sync, changes it and so ends the segment.
  var watermark: String { summary?.record.ref.key.rawValue ?? "" }

  var summaryClaimsUnrestricted: Bool { summary.map { $0.record.contentMode != .known(.standard) } ?? false }

  // chat-compaction.service.ts:74-77
  func history(for turnMode: ContentMode) -> [PromptMessage] {
    opening(for: turnMode) + messages.flatMap { render($0, for: turnMode) }
  }

  // chat-compaction.service.ts:97-101
  func opening(for turnMode: ContentMode) -> [PromptMessage] {
    guard let summary else { return [] }
    let text = turnMode == .standard && summaryClaimsUnrestricted ? unrestrictedSummaryPlaceholder : summary.record.text
    return sendable(PromptMessage(.user, "Conversation so far (compacted summary):\n\(text)"))
  }

  /// A standard turn never reads what the unrestricted model wrote, and an unrestricted turn leaves out an author's message the hard line refuses. A message
  /// that renders blank is left out, as a request refuses one.
  // chat-compaction.service.ts:102-107
  func render(_ message: ChatWindowMessage, for turnMode: ContentMode) -> [PromptMessage] {
    switch message.role {
    case .user:
      guard turnMode == .standard || !message.refusesAuthored else { return [] }
      return sendable(PromptMessage(.user, renderTurnContent(message.record.content, contexts: message.record.passageContexts)))
    case .assistant:
      guard turnMode == .unrestricted || !message.claimsUnrestricted else { return [PromptMessage(.assistant, unrestrictedReplyPlaceholder)] }
      let asked = renderQuestionForHistory(message.record.question.map(OrderedJSON.init))
      return sendable(PromptMessage(.assistant, asked.map { "\(message.record.content)\n\n\($0)" } ?? message.record.content))
    }
  }

  private func sendable(_ message: PromptMessage) -> [PromptMessage] {
    message.text.allSatisfy(\.isWhitespace) ? [] : [message]
  }
}

extension ChatConversationWindow {
  static func load(_ session: UUID, in transaction: ReadTransaction) throws(ChatCompactionError) -> ChatConversationWindow {
    let window: ChatWindow
    do {
      window = try ChatWindow.load(session, in: transaction)
    } catch {
      throw .store(error)
    }
    switch window.window {
    case .available(let contents): return ChatConversationWindow(session: session, contents: contents, lock: window.lock)
    case .unavailable(let faults): throw .windowUnavailable(faults)
    }
  }
}
