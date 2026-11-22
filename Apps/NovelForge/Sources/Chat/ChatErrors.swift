import Foundation
import NovelForgeCore
import ShadowAI
import ShadowAppShell

struct ChatNotice: Equatable {
  let error: PresentedError
  let opensSettings: Bool
}

struct ChatFailureCopy: Equatable {
  let title: String
  let reason: String
  let opensSettings: Bool
}

enum ChatErrors {
  static func notice(_ error: ChatTurnError) -> ChatNotice {
    guard case .routing(let routing) = error else { return ChatNotice(error: presented(error), opensSettings: false) }
    return ChatNotice(error: AIErrors.presented(routing, app: .novelForge), opensSettings: opensSettings(routing))
  }

  static func presented(_ error: ChatTurnError) -> PresentedError {
    switch error {
    case .routing(let routing): AIErrors.presented(routing, app: .novelForge)
    case .store(let store): PresentedError(store)
    default: PresentedError(headline: headline(for: error), detail: error.code)
    }
  }

  static func presented(_ error: ChatSessionError) -> PresentedError {
    switch error {
    case .store(let store): PresentedError(store)
    case .novelNotFound, .notFound: PresentedError(headline: missingChat, detail: error.code)
    case .unreadable:
      PresentedError(headline: String(localized: "This chat is stored in a form this version cannot read, so it cannot be changed here.", table: "Chat"), detail: error.code)
    case .record(.titleTooLong(let limit)): PresentedError(headline: String(localized: "A chat title is at most \(limit) characters.", table: "Chat"), detail: error.code)
    case .record: PresentedError(headline: String(localized: "This chat could not be saved.", table: "Chat"), detail: error.code)
    }
  }

  // apps/novel-forge-web/src/components/nf/TurnStatus.tsx:27-39: a code without copy gets the generic words, so a new code reads as vague rather than wrong
  static func copy(for failure: TurnFailure) -> ChatFailureCopy {
    let code = failure.code
    switch code {
    case "CHT_013":
      return copy("This reply was interrupted", "The app closed while it was being written.")
    case "routing.credential_missing":
      return copy("No AI key is set up", "Add your key in AI settings, then try again.", opensSettings: true)
    case "routing.consent_required":
      return copy("Novel Forge needs your permission first", "Try again to choose whether to send this.")
    case "routing.no_route", "routing.unrestricted_model_missing", "routing.provider_missing", "model.no_eligible_model":
      return copy("No model can take this right now", "Nothing can serve this call at this novel's pace right now.", opensSettings: true)
    case "routing.daily_spend_limit", "routing.monthly_spend_limit":
      return copy("AI spending limit reached", "Model calls are paused until the limit resets or you raise it.", opensSettings: true)
    case "routing.spend_unavailable", "routing.ledger":
      return copy("Your AI spend could not be checked", "Nothing was sent to the model.")
    case "model.authentication", "model.forbidden":
      return copy("The provider did not accept your key", "Check your key in AI settings.", opensSettings: true)
    case "model.insufficient_credits":
      return copy("The provider account has run out of credit", "Add credit with the provider, then try again.")
    case "model.rate_limited", "model.overloaded":
      return copy("Too many model calls right now", "Wait a moment, then try again.")
    case "model.transport", "model.server", "model.mid_stream":
      return copy("Couldn't reach the model", "It didn't respond. Try again shortly.")
    case "chat_turn.unreadable_reply", "model.malformed_response", "structured.invalid", "structured.decoding", "structured.truncated", "structured.refused":
      return copy("The model's answer came back unreadable", "It replied, but not in a shape that could be used.")
    case "chat_turn.request_too_large":
      return copy(
        "This conversation is too long for one request", "Start a new chat, or shorten your message and the passages it quotes, then send it again.")
    case "AI_024":
      return copy("Unrestricted writing isn't available right now", "Switch to Standard, or send without Unrestricted, to keep writing.")
    case "AI_015":
      return copy("This reply was held back", "It crossed a hard line, so nothing it wrote was kept.")
    default:
      return copy("That turn didn't finish", "Something went wrong.")
    }
  }

  static var missingChat: String { String(localized: "This chat could not be found. It may have been deleted on another device.", table: "Chat") }

  private static func copy(_ title: String.LocalizationValue, _ reason: String.LocalizationValue, opensSettings: Bool = false) -> ChatFailureCopy {
    ChatFailureCopy(title: String(localized: title, table: "Chat"), reason: String(localized: reason, table: "Chat"), opensSettings: opensSettings)
  }

  private static func opensSettings(_ error: TaskRouterError) -> Bool {
    switch error {
    case .noRoute, .unrestrictedModelMissing, .providerMissing, .credentialMissing, .dailySpendLimitReached, .monthlySpendLimitReached: true
    case .consentRequired, .spendUnavailable, .ledger: false
    }
  }

  private static func headline(for error: ChatTurnError) -> String {
    switch error {
    case .sessionNotFound, .novelNotFound: missingChat
    case .sessionArchived: String(localized: "This chat is archived. Unarchive it to keep chatting.", table: "Chat")
    case .emptyMessage: String(localized: "Write a message before sending.", table: "Chat")
    case .messageTooLong(let limit): String(localized: "A message is at most \(limit) characters.", table: "Chat")
    case .tooManyPassages(let limit): String(localized: "A message carries at most \(limit) passage comments.", table: "Chat")
    case .invalidPassage, .passage(code: "CHT_009", _), .passage(code: "CHT_010", _): String(localized: "A passage you commented on changed. Select it again.", table: "Chat")
    case .passage: String(localized: "That chapter is isolated, so its passages cannot be sent to the chat. Remove the comment.", table: "Chat")
    case .hardLine: String(localized: "Novel Forge will not send this message: it crosses a hard line.", table: "Chat")
    case .unrestrictedUnavailable: String(localized: "Unrestricted writing isn't available in this version. Send it as standard writing instead.", table: "Chat")
    case .messageNotAnswerable: String(localized: "This message cannot be answered on this device.", table: "Chat")
    case .turnRunning: String(localized: "A reply is already being written in this chat.", table: "Chat")
    case .turnNotRetryable: String(localized: "This reply can no longer be tried again.", table: "Chat")
    case .conversationUnavailable: String(localized: "The earlier conversation could not be read, so nothing was sent.", table: "Chat")
    case .routing, .store: String(localized: "Something went wrong.", table: "Chat")
    }
  }
}
