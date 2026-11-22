import Foundation
import MemoirCore
import ShadowAI
import ShadowAppShell

extension ConsentDisclosure {
  nonisolated static let memoirInsights = disclosure(
    InsightConsent.call, title: { String(localized: "Your quests, progress and logs", table: "AI") },
    explanation: { provider in
      String(
        localized:
          "To answer a question, Memoir sends it with your quests and their history, your hero's progress, your money, meals, side quests and general metrics to \(provider). \(provider) processes them under its own terms.",
        table: "AI")
    })

  nonisolated static let memoirJournal = disclosure(
    InsightConsent.requirement(for: .journalReflectionReason), title: { String(localized: "Your journal and reflections", table: "AI") },
    explanation: { provider in
      String(
        localized:
          "With this, Memoir also sends your journal entries, your reflections and the reasons you noted for quests to \(provider). Without it, none of them is read for a question.",
        table: "AI")
    })

  nonisolated static let memoirHealth = disclosure(
    InsightConsent.requirement(for: .health), title: { String(localized: "Your health and activity data", table: "AI") },
    explanation: { provider in
      String(
        localized:
          "With this, Memoir also sends your health and activity data, such as weight, sleep, heart rate, steps and workouts, to \(provider). Without it, none of them is read for a question.",
        table: "AI")
    })

  nonisolated static let memoir = [memoirInsights, memoirJournal, memoirHealth, memoirReceipts]

  nonisolated private static func disclosure(
    _ requirement: AIConsentRequirement, title: @escaping @Sendable () -> String, explanation: @escaping @Sendable (String) -> String
  ) -> ConsentDisclosure {
    ConsentDisclosure(id: requirement.disclosure, dataClass: requirement.dataClass, title: title, explanation: explanation)
  }
}

extension AIServices {
  /// MemoirCore screens no request, so no route gets a request guard; its insights check what comes back.
  static func memoir(defaults: UserDefaults = .standard) -> AIServices {
    live(identity: .memoir, disclosures: ConsentDisclosure.memoir, requestGuard: { _ in nil }, defaults: defaults)
  }
}
