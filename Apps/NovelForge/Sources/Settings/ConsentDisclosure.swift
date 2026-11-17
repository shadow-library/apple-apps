import Foundation
import ShadowAI

nonisolated enum ConsentDisclosure: String, CaseIterable, Sendable {
  case novelText = "novel-text/v2"

  init?(_ request: AIConsentRequest) {
    guard let disclosure = Self(rawValue: request.disclosure), disclosure.dataClass == request.dataClass else { return nil }
    self = disclosure
  }

  var id: String { rawValue }

  var dataClass: String {
    switch self {
    case .novelText: "novel-text"
    }
  }

  var requirement: AIConsentRequirement { AIConsentRequirement(dataClass: dataClass, disclosure: id) }

  var title: String {
    switch self {
    case .novelText: String(localized: "Your novel's text", table: "Settings")
    }
  }

  func explanation(provider: String) -> String {
    switch self {
    case .novelText:
      String(
        localized:
          "To answer a request, Novel Forge sends the parts of your novel it needs, such as chapter text, story bible entries and notes, together with your message, the earlier conversation in that chat (your messages, its replies and summaries of older turns) and, when the model asks for them, your AI usage and spending figures, to \(provider). \(provider) processes them under its own terms.",
        table: "Settings")
    }
  }
}

extension ModelProviderKind {
  var displayName: String {
    switch self {
    case .anthropic: "Anthropic"
    case .openRouter: "OpenRouter"
    }
  }
}

extension Pace {
  var displayName: String {
    switch self {
    case .swift: String(localized: "Swift", table: "Settings")
    case .steady: String(localized: "Steady", table: "Settings")
    case .meticulous: String(localized: "Meticulous", table: "Settings")
    }
  }
}
