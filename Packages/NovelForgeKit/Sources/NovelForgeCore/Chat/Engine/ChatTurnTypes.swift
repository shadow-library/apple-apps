import Foundation
import ShadowAI
import ShadowCore
import ShadowStore

/// The author's choices for one turn, recorded on their message so a retry or another device answers it the same way; nil follows the novel
/// (apps/novel-forge-server/src/modules/refinement/chat.dto.ts:486-511).
public struct ChatTurnChoices: Sendable, Equatable {
  public var pace: CostTier?
  public var thinksDeeper: Bool
  public var contentMode: ContentMode?
  public var justDiscussing: Bool
  public var proseEdits: Bool

  public init(pace: CostTier? = nil, thinksDeeper: Bool = false, contentMode: ContentMode? = nil, justDiscussing: Bool = false, proseEdits: Bool = false) {
    self.pace = pace
    self.thinksDeeper = thinksDeeper
    self.contentMode = contentMode
    self.justDiscussing = justDiscussing
    self.proseEdits = proseEdits
  }
}

/// A passage the author commented on, as the Reader selected it: offsets are UTF-16 code units into the draft at `revision` (chat.dto.ts:234-264).
public struct ChatTurnPassage: Sendable, Equatable {
  public var chapter: Int
  public var draftId: String
  public var revision: Int
  public var saveSeq: Int?
  public var start: Int
  public var end: Int
  public var passageHash: String
  public var quote: String
  public var comment: String

  public init(chapter: Int, draftId: String, revision: Int, saveSeq: Int? = nil, start: Int, end: Int, passageHash: String, quote: String, comment: String) {
    self.chapter = chapter
    self.draftId = draftId
    self.revision = revision
    self.saveSeq = saveSeq
    self.start = start
    self.end = end
    self.passageHash = passageHash
    self.quote = quote
    self.comment = comment
  }

  var input: PassageContextInput {
    PassageContextInput(
      chapter: chapter, draftId: draftId, revision: revision, saveSeq: saveSeq, start: start, end: end, passageHash: passageHash, quote: quote, comment: comment)
  }
}

public enum ChatTurnOutcome: Sendable, Equatable {
  case answered(reply: UUID)
  case failed(TurnFailure)
  /// The author stopped it: terminal, never retried automatically.
  case cancelled
  /// Stopped without ending, as when the system ends the background grace; it stays pending to resume on this device.
  case interrupted
}

/// A running turn. `turn` is the local turn's id and the id its reply will have; `events` ends with the turn.
public struct ChatTurnHandle: Sendable {
  public let turn: UUID
  public let userMessage: UUID
  public let events: AsyncStream<TurnStreamEvent>
  let task: Task<ChatTurnOutcome, Never>

  public func outcome() async -> ChatTurnOutcome {
    await task.value
  }
}

/// What a session's transcript shows about its turn on this device. A transcript ending on an author message with no turn here is being answered on another
/// device, or by a database this one was restored from (orchestrator decision 6); `Answer here` runs it here and both replies stand.
public enum ChatTurnActivity: Sendable, Equatable {
  case idle
  case running(LocalTurn)
  /// Pending on this device but not running, as after the background grace ended: it offers Resume.
  case interrupted(LocalTurn)
  case ended(LocalTurn)
  case answeringElsewhere(message: UUID)
}

/// Why a turn was refused before the author's message was saved; nothing was written.
public enum ChatTurnError: ShadowError {
  case sessionNotFound
  case sessionArchived
  case novelNotFound
  case emptyMessage
  case messageTooLong(limit: Int)
  case tooManyPassages(limit: Int)
  case invalidPassage(index: Int)
  case passage(code: String, chapter: Int)
  case hardLine(code: String, message: String)
  case messageNotAnswerable
  case turnRunning
  case turnNotRetryable
  case conversationUnavailable(code: String, message: String)
  case routing(TaskRouterError)
  case store(StoreError)

  public var code: String {
    switch self {
    case .sessionNotFound: "CHT_001"
    case .sessionArchived: "CHT_002"
    case .novelNotFound: "chat_turn.novel_not_found"
    case .emptyMessage: "CHT_012"
    case .messageTooLong: "chat_turn.message_too_long"
    case .tooManyPassages: "chat_turn.too_many_passages"
    case .invalidPassage: "chat_turn.invalid_passage"
    case .passage(let code, _): code
    case .hardLine(let code, _): code
    case .messageNotAnswerable: "chat_turn.message_not_answerable"
    case .turnRunning: "chat_turn.running"
    case .turnNotRetryable: "chat_turn.not_retryable"
    case .conversationUnavailable(let code, _): code
    case .routing(let error): error.code
    case .store(let error): error.code
    }
  }

  // apps/novel-forge-server/src/classes/app-error-code.ts:150-161 for the CHT codes
  public var errorDescription: String? {
    switch self {
    case .sessionNotFound: "Chat session not found"
    case .sessionArchived: "Chat session is archived"
    case .novelNotFound: "This chat's novel could not be found."
    case .emptyMessage: "Write a message or comment on a passage before sending"
    case .messageTooLong(let limit): "A message is at most \(limit) characters."
    case .tooManyPassages(let limit): "A message carries at most \(limit) passage comments."
    case .invalidPassage(let index): "Passage comment \(index + 1) is not a selection of a chapter — select the passage again."
    case .passage(let code, let chapter):
      switch code {
      case "CHT_009": "That passage in chapter \(chapter) changed — select it again"
      case "CHT_011": "Chapter \(chapter) is isolated, so its passages cannot be sent to the chat — remove the comment"
      default: "A passage comment on chapter \(chapter) does not match its quote — select the passage again"
      }
    case .hardLine(_, let message): message
    case .messageNotAnswerable: "That message cannot be answered on this device: it is not an author message this device can read."
    case .turnRunning: "A turn is already running in this chat."
    case .turnNotRetryable: "Only a turn that failed or was stopped can be tried again."
    case .conversationUnavailable(_, let message): message
    case .routing(let error): error.errorDescription
    case .store(let error): error.errorDescription
    }
  }
}

/// The background grace a platform gives a turn that is running when the app leaves the screen; the app wires it (phase 8 adds background continuation).
/// `expire` stops the turn without ending it, so it stays pending and resumes from its last saved round.
public protocol ChatTurnGrace: Sendable {
  func turnStarted(_ turn: UUID, expire: @escaping @Sendable () -> Void)
  func turnEnded(_ turn: UUID)
}

public struct NoChatTurnGrace: ChatTurnGrace {
  public init() {}

  public func turnStarted(_ turn: UUID, expire: @escaping @Sendable () -> Void) {}

  public func turnEnded(_ turn: UUID) {}
}
