import Foundation
import MemoirCore
import ShadowAI
import ShadowAppShell
import ShadowCore
import ShadowDesignSystem
import ShadowStore
import SwiftUI

/// The Ask screen's words, ported from memoir-web's coach copy (`synced-reflect-provider.ts:42-66`, `features/ai/index.tsx`) where the native flow keeps
/// its meaning; quota and plan copy has no counterpart here, since the owner pays their own provider.
enum AskCopy {
  static func label(_ status: InsightRequestStatus) -> Text {
    switch status {
    case .queued: Text("Queued", tableName: "Ask")
    case .running: Text("Reading", tableName: "Ask")
    case .succeeded: Text("Ready", tableName: "Ask")
    case .failed: Text("Did not finish", tableName: "Ask")
    case .cancelled: Text("Cancelled", tableName: "Ask")
    }
  }

  static func intent(_ status: InsightRequestStatus) -> ShadowBadgeIntent {
    switch status {
    case .queued, .cancelled: .neutral
    case .running: .info
    case .succeeded: .success
    case .failed: .warning
    }
  }

  static func body(_ status: InsightRequestStatus) -> Text {
    switch status {
    case .queued: Text("Waiting to start. If it was asked on a device that is no longer open, ask it again here.", tableName: "Ask")
    case .running: Text("Reading your history now. Keep Memoir open — the answer will be waiting here.", tableName: "Ask")
    case .succeeded: Text("The answer is below.", tableName: "Ask")
    case .failed: Text("The run could not finish. Asking again is safe.", tableName: "Ask")
    case .cancelled: Text("The request was cancelled.", tableName: "Ask")
    }
  }

  static func title(_ request: InsightRequest) -> Text {
    switch request.kind {
    case .scheduled: Text("Nightly summary", tableName: "Ask")
    case .adhoc: request.question.isEmpty ? Text("Your question", tableName: "Ask") : Text(verbatim: request.question)
    }
  }

  static func failure(code: String) -> PresentedError {
    let headline =
      switch code {
      case InsightError.guardrailBlocked([]).code:
        String(localized: "The answer was held back because it broke Memoir’s rules for answers. Asking again is safe.", table: "Ask")
      case InsightError.refused.code: String(localized: "The AI service declined to answer this question.", table: "Ask")
      case InsightError.contextTooLarge(units: 0, budget: 0).code:
        String(localized: "Even your last week of data is too much to send in one question.", table: "Ask")
      default: String(localized: "The run could not finish. Asking again is safe.", table: "Ask")
      }
    return PresentedError(headline: headline, detail: code)
  }

  static func presented(_ error: any Error) -> PresentedError {
    switch error {
    case InsightError.routing(let routing): AIErrors.presented(routing, app: .memoir)
    case InsightError.questionLength:
      PresentedError(headline: String(localized: "A question has 1 to 2,000 characters.", table: "Ask"), detail: InsightError.questionLength(0).code)
    case let insight as InsightError where insight.code.hasPrefix("insight."): failure(code: insight.code)
    case StoreError.aborted(let inner): presented(inner)
    default: PresentedError(error)
    }
  }

  static func money(_ cost: Cost) -> String {
    AIErrors.money(cost)
  }
}
