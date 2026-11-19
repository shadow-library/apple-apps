import Foundation
import NovelForgeCore
import ShadowDesignSystem
import ShadowJobs
import SwiftUI

enum JobDisplay {
  // apps/novel-forge-web/src/features/chapters/chapter-status.ts:11-22; Finalizing and the step on Generating are deviations (ChapterStatus)
  static func chip(_ status: ChapterStatus) -> (label: String, intent: ShadowBadgeIntent, systemImage: String) {
    switch status {
    case .drafting: (String(localized: "Draft", table: "Jobs"), .neutral, "pencil.line")
    case .generating(let step?): (String(localized: "Generating · \(progress(.generate, step))", table: "Jobs"), .info, "sparkles")
    case .generating(nil): (String(localized: "Generating", table: "Jobs"), .info, "sparkles")
    case .needsReview: (String(localized: "Needs review", table: "Jobs"), .warning, "exclamationmark.bubble")
    case .contradiction: (String(localized: "Conflict", table: "Jobs"), .danger, "exclamationmark.triangle")
    case .approved: (String(localized: "Approved", table: "Jobs"), .success, "checkmark.circle")
    case .finalizing: (String(localized: "Finalizing", table: "Jobs"), .info, "books.vertical")
    case .final: (String(localized: "Final", table: "Jobs"), .success, "checkmark.seal.fill")
    }
  }

  static func title(_ kind: NovelJobKind) -> Text {
    switch kind {
    case .generate: Text("Writing the chapter", tableName: "Jobs")
    case .plan: Text("Planning the chapter", tableName: "Jobs")
    case .review: Text("Checking the chapter", tableName: "Jobs")
    case .finalizeReview: Text("Reading the Story Bible updates", tableName: "Jobs")
    case .canonRefresh: Text("Refreshing the Story Bible", tableName: "Jobs")
    }
  }

  static func title(_ line: ChapterJobLine) -> Text {
    guard line.kind == .review, let reviewKind = line.reviewKind else { return title(line.kind) }
    return Text(verbatim: ChecksDisplay.label(reviewKind))
  }

  static func message(_ line: ChapterJobLine) -> Text {
    switch line.state {
    case .runningHere(let step?): Text(verbatim: progress(line.kind, step))
    case .runningHere(nil): Text("Running on this device", tableName: "Jobs")
    case .runningOnAnotherDevice: Text("Running on another device", tableName: "Jobs")
    case .resumingHere: Text("Resuming on this device", tableName: "Jobs")
    case .runningInAnotherCopy: Text("Running in another copy of Novel Forge", tableName: "Jobs")
    case .startedOnThisDevice: Text("Started on this device", tableName: "Jobs")
    case .queued: Text("Waiting to start", tableName: "Jobs")
    case .waitingForConsent: Text("Waiting for your permission to send this novel's text to the AI provider", tableName: "Jobs")
    case .failed(let failure): Text(verbatim: JobsErrors.failure(failure))
    }
  }

  static func intent(_ line: ChapterJobLine) -> ShadowIntent {
    switch line.state {
    case .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice: .info
    case .queued: .neutral
    case .waitingForConsent: .warning
    case .failed: .danger
    }
  }

  static var runHere: Text {
    #if os(macOS)
      Text("Run on This Mac", tableName: "Jobs")
    #else
      Text("Run on This Device", tableName: "Jobs")
    #endif
  }

  /// The step a run is at, by number, and for a generation by name (GenerationStep's names).
  static func progress(_ kind: NovelJobKind, _ step: AttemptStep) -> String {
    let number = step.index + 1
    guard kind == .generate, let label = generationStep(step.name) else { return String(localized: "Step \(number)", table: "Jobs") }
    return String(localized: "Step \(number) · \(label)", table: "Jobs")
  }

  private static func generationStep(_ name: String) -> String? {
    switch name {
    case "pin": String(localized: "Preparing", table: "Jobs")
    case "draft": String(localized: "Drafting", table: "Jobs")
    case "expand": String(localized: "Expanding", table: "Jobs")
    case "title": String(localized: "Titling", table: "Jobs")
    case "save": String(localized: "Saving", table: "Jobs")
    case "checks": String(localized: "Checking", table: "Jobs")
    case "judge": String(localized: "Judging", table: "Jobs")
    case "repair": String(localized: "Repairing", table: "Jobs")
    case "rewrite": String(localized: "Rewriting", table: "Jobs")
    case "finish": String(localized: "Finishing", table: "Jobs")
    default: nil
    }
  }
}
