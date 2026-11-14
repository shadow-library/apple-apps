import ShadowDesignSystem
import SwiftUI

struct CalloutPage: View {
  @State private var dismissed = false

  var body: some View {
    ComponentPage(component: .callout) {
      StateSection("Intents", note: "Info, success, warning and danger. The tone is carried by the symbol and the words too, never colour alone.") {
        VStack(spacing: Spacing.space3) {
          ShadowCallout("Wikis unlock as you read", message: "Entries appear once you reach the chapter that reveals them.")
          ShadowCallout("Chapter 42 is canon", message: "Readers on Web Novel see it on Friday.", intent: .success)
          ShadowCallout("Budget at 82%", message: "Synapse pauses AI drafts at 100% this month.", intent: .warning)
          ShadowCallout("Email delivery failed", message: "Resend rejected 3 messages. Check the sender domain.", intent: .danger)
        }
      }
      StateSection("Neutral", note: "For context that is not a status, such as a note about the current screen.") {
        ShadowCallout("Drafts are private", message: "Only you can see a draft until you schedule it.", intent: .neutral)
      }
      StateSection("Action and dismiss", note: "One optional action sits under the message; dismissing is for callouts that can safely come back.") {
        VStack(spacing: Spacing.space3) {
          ShadowCallout("Email delivery failed", message: "Resend rejected 3 messages. Check the sender domain.", intent: .danger) {
            Button("Review failures") {}
          }
          if !dismissed {
            ShadowCallout("Budget at 82%", message: "Synapse pauses AI drafts at 100% this month.", intent: .warning, dismiss: ShadowCalloutDismiss("Dismiss") { dismissed = true })
            {
              Button("Raise budget") {}
            }
          } else {
            Button("Show the budget callout again") { dismissed = false }.buttonStyle(.shadowBordered)
          }
        }
      }
      StateSection("Title only", note: "A short fact needs no body.") {
        ShadowCallout("Saved to your library", intent: .success)
      }
      StateSection("Long text", note: "Title and message wrap; the symbol stays top-aligned with the title.") {
        ShadowCallout(
          "Some of your chapters could not be published to Web Novel because the connection was lost while they were uploading",
          message:
            "Your drafts are safe. Check your connection, then choose Publish again. If the problem continues, contact support with the chapter numbers listed in the activity log.",
          intent: .danger,
          dismiss: ShadowCalloutDismiss("Dismiss") {}
        ) {
          Button("Try again") {}
        }
      }
      StateSection("Intents in light and dark", note: "Fill, border and text are the intent’s bg-subtle, border and text-on-subtle tokens.") {
        SchemePair {
          VStack(spacing: Spacing.space2) {
            ForEach(ShadowIntent.allCases, id: \.self) { intent in
              ShadowCallout(title(for: intent), message: "Next step goes here.", intent: intent)
            }
          }
        }
      }
    }
  }

  private func title(for intent: ShadowIntent) -> LocalizedStringKey {
    switch intent {
    case .neutral: "Drafts are private"
    case .info: "Wikis unlock as you read"
    case .success: "Chapter 42 is canon"
    case .warning: "Budget at 82%"
    case .danger: "Email delivery failed"
    }
  }
}
