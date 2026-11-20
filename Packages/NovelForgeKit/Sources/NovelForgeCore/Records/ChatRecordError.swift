import ShadowCore
import ShadowText

public enum ChatRecordError: ShadowError, Equatable {
  case blankTitle
  case titleTooLong(limit: Int)
  case emptyMessage
  case contentTooLong(limit: Int)
  case tooManyContexts(limit: Int)
  case malformedContext(index: Int)
  case malformedQuestion
  case blankSummary
  case noCoveredMessages

  public var code: String {
    switch self {
    case .blankTitle: "chat_record.blank_title"
    case .titleTooLong: "chat_record.title_too_long"
    case .emptyMessage: "chat_record.empty_message"
    case .contentTooLong: "chat_record.content_too_long"
    case .tooManyContexts: "chat_record.too_many_contexts"
    case .malformedContext: "chat_record.malformed_context"
    case .malformedQuestion: "chat_record.malformed_question"
    case .blankSummary: "chat_record.blank_summary"
    case .noCoveredMessages: "chat_record.no_covered_messages"
    }
  }

  public var errorDescription: String? {
    switch self {
    case .blankTitle: "A chat title cannot be blank."
    case .titleTooLong(let limit): "A chat title is at most \(limit) characters."
    case .emptyMessage: "A message needs text or at least one passage comment."
    case .contentTooLong(let limit): "A message is at most \(limit) characters."
    case .tooManyContexts(let limit): "A message carries at most \(limit) passages."
    case .malformedContext(let index): "Passage \(index) is not a stored passage context."
    case .malformedQuestion: "The question card is not 2 to 4 answers under a question."
    case .blankSummary: "A summary needs text."
    case .noCoveredMessages: "A summary covers at least one message."
    }
  }
}

// apps/novel-forge-server/src/database/schemas/refinement.ts:166
let maxChatTitleCharacters = 500

// apps/novel-forge-server/src/modules/refinement/chat.dto.ts:471-476
let maxChatTurnCharacters = 200_000

func validatedChatTitle(_ text: String) throws(ChatRecordError) -> String {
  guard !text.jsTrim().isEmpty else { throw .blankTitle }
  guard text.unicodeScalars.count <= maxChatTitleCharacters else { throw .titleTooLong(limit: maxChatTitleCharacters) }
  return text
}
