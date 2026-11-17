import Foundation
import ShadowAI
import ShadowCore
import ShadowStore

/// How a turn that saved the author's message but no reply says why, in the words the transcript shows (turn-stream.service.ts:96 sends the error's code and
/// message).
enum ChatTurnFailures {
  static let requestTooLargeCode = "chat_turn.request_too_large"
  static let requestTooLarge =
    "This conversation is too long for the model to read in one request. Start a new chat, or shorten your message and the passages it quotes, then send it again."
  static let unreadableReplyCode = "chat_turn.unreadable_reply"
  static let unreadableReply = "The model's answer could not be read as a reply."

  /// Providers name an oversized request only in a 413 or in their message (Anthropic `request_too_large`, "prompt is too long"; OpenRouter's context
  /// length), which `ModelError` keeps as an invalid request.
  private static let tooLargeMarks = ["413", "too large", "too long", "request_too_large", "context length", "context_length", "maximum context"]

  static func failure(_ error: StructuredError) -> TurnFailure {
    if let hit = error.hardLineHit { return hardLine(hit) }
    if case .model(.invalidRequest(let message), _) = error, tooLargeMarks.contains(where: message.lowercased().contains) {
      return TurnFailure(code: requestTooLargeCode, message: requestTooLarge)
    }
    return TurnFailure(code: error.code, message: error.errorDescription ?? error.code)
  }

  static func failure(_ error: some ShadowError) -> TurnFailure {
    TurnFailure(code: error.code, message: error.errorDescription ?? error.code)
  }

  static func hardLine(_ hit: HardLineHit) -> TurnFailure {
    failure(hardLineError(hit))
  }
}
