import NovelForgeCore

/// Why the author's waiting message cannot be answered on this device, as `ChatTurnPreparation` would refuse it; the engine's activity does not say.
nonisolated enum ChatAnswerBlock: Equatable, Sendable {
  /// It asks for unrestricted writing while this build cannot do it (AI_024).
  case unrestricted
  /// F26 finding B: compaction folded it into the chat's summary, so no turn can answer it (chat_turn.message_not_answerable).
  case folded
  /// Its record, or a passage it points at, cannot be read here (chat_turn.message_not_answerable).
  case unreadable

  /// `novelMode` is what a message with no recorded mode follows (chat-selection.ts:22).
  static func of(_ message: ChatTranscriptMessage, novelMode: ContentMode) -> ChatAnswerBlock? {
    guard let record = message.record, record.role == .known(.user), !message.row.hasUnreadableContexts else { return .unreadable }
    if message.isCovered { return .folded }
    guard !UnrestrictedWriting.isAvailable else { return nil }
    return (record.contentMode?.known ?? novelMode) == .unrestricted ? .unrestricted : nil
  }
}
