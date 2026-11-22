import Foundation
import NovelForgeCore
import ShadowAppShell
import ShadowJobs
import SwiftUI

/// The system's progress UI for a run here: the job's kind and chapter as the title, its step as the subtitle.
enum ContinuedProcessingText {
  static func title(_ target: NovelJobTarget?) -> String {
    guard let target else { return String(localized: "Running a chapter job", table: "Jobs") }
    let chapter = target.chapter
    return switch target.kind {
    case .generate: String(localized: "Writing chapter \(chapter)", table: "Jobs")
    case .plan: String(localized: "Planning chapter \(chapter)", table: "Jobs")
    case .review: String(localized: "Checking chapter \(chapter)", table: "Jobs")
    case .finalizeReview: String(localized: "Reading the Story Bible updates for chapter \(chapter)", table: "Jobs")
    case .canonRefresh: String(localized: "Refreshing the Story Bible after chapter \(chapter)", table: "Jobs")
    }
  }

  static func subtitle(_ target: NovelJobTarget?, step: AttemptStep?) -> String {
    guard let step else { return String(localized: "Starting", table: "Jobs") }
    guard let kind = target?.kind else { return String(localized: "Step \(step.index + 1)", table: "Jobs") }
    return JobDisplay.progress(kind, step)
  }

  static var keepOpen: Text {
    Text("Keep Novel Forge open until this finishes.", tableName: "Jobs")
  }
}
