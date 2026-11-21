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

  /// Decision 8 of phase 8: a run elsewhere names its device, step and last renewal; a queued job says who starts it, when it was asked for and where its
  /// last attempt stopped; a run stopped here says where and when.
  static func message(_ line: ChapterJobLine, now: Date = Date()) -> Text {
    Text(verbatim: summary(line, now: now))
  }

  static func summary(_ line: ChapterJobLine, now: Date) -> String {
    switch line.state {
    case .runningHere(let step?): progress(line.kind, step)
    case .runningHere(nil): String(localized: "Running on this device", table: "Jobs")
    case .runningOnAnotherDevice(let elsewhere):
      joined(
        elsewhere.device.map { String(localized: "Running on \($0)", table: "Jobs") } ?? String(localized: "Running on another device", table: "Jobs"),
        elsewhere.step.map { progress(line.kind, $0) }, elsewhere.renewed.map { String(localized: "updated \(relative($0, now: now))", table: "Jobs") })
    case .resumingHere: String(localized: "Resuming on this device", table: "Jobs")
    case .runningInAnotherCopy: String(localized: "Running in another copy of Novel Forge", table: "Jobs")
    case .startedOnThisDevice: String(localized: "Started on this device", table: "Jobs")
    case .queued(let wait):
      joined(
        starter(wait.starter), wait.requested.map { String(localized: "requested \(relative($0, now: now))", table: "Jobs") },
        wait.stopped.flatMap { stop(line.kind, $0, now: now) })
    case .interrupted(let stop): joined(String(localized: "Interrupted on this device", table: "Jobs"), self.stop(line.kind, stop, now: now))
    case .waitingForConsent: String(localized: "Waiting for your permission to send this novel's text to the AI provider", table: "Jobs")
    case .failed(let failure): JobsErrors.failure(failure)
    }
  }

  static func intent(_ line: ChapterJobLine) -> ShadowIntent {
    switch line.state {
    case .runningHere, .resumingHere, .runningOnAnotherDevice, .runningInAnotherCopy, .startedOnThisDevice: .info
    case .queued: .neutral
    case .interrupted, .waitingForConsent: .warning
    case .failed: .danger
    }
  }

  static var resume: Text {
    Text("Resume", tableName: "Jobs")
  }

  /// A moment in the past as "2 minutes ago"; one a clock ahead of this one stamped reads as now.
  static func relative(_ date: Date, now: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    formatter.dateTimeStyle = .named
    return formatter.localizedString(for: min(date, now), relativeTo: now)
  }

  /// The time of day, with the date when it is not today.
  static func clockTime(_ date: Date, now: Date) -> String {
    date.formatted(date: Calendar.current.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
  }

  private static func starter(_ starter: JobWait.Starter) -> String {
    switch starter {
    case .here: String(localized: "Waiting to start", table: "Jobs")
    case .you: String(localized: "Waiting for you to run it", table: "Jobs")
    case .worker(let name?): String(localized: "Waiting for \(name)", table: "Jobs")
    case .worker(nil): String(localized: "Waiting for the Mac that runs jobs", table: "Jobs")
    case .noWorker: String(localized: "No Mac runs jobs", table: "Jobs")
    case .requester(let name?): String(localized: "Waiting for \(name)", table: "Jobs")
    case .requester(nil): String(localized: "Waiting for the device that asked for it", table: "Jobs")
    }
  }

  private static func stop(_ kind: NovelJobKind, _ stop: JobStop, now: Date) -> String? {
    let time = stop.at.map { at in
      stop.released
        ? String(localized: "stopped at \(clockTime(at, now: now))", table: "Jobs") : String(localized: "last updated \(relative(at, now: now))", table: "Jobs")
    }
    let parts = [stop.step.map { progress(kind, $0) }, time].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private static func joined(_ parts: String?...) -> String {
    parts.compactMap { $0 }.joined(separator: " · ")
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
