import Foundation
import ShadowAI
import ShadowAppShell

extension ConsentDisclosure {
  nonisolated static let novelText = ConsentDisclosure(
    id: "novel-text/v2", dataClass: "novel-text", title: { String(localized: "Your novel's text", table: "Settings") },
    explanation: { provider in
      String(
        localized:
          "To answer a request, Novel Forge sends the parts of your novel it needs, such as chapter text, story bible entries and notes, together with your message, the earlier conversation in that chat (your messages, its replies and summaries of older turns) and, when the model asks for them, your AI usage and spending figures, to \(provider). \(provider) processes them under its own terms.",
        table: "Settings")
    })

  nonisolated static let novelForge = [novelText]

  nonisolated init?(_ request: AIConsentRequest) {
    self.init(request, among: Self.novelForge)
  }
}
