import Foundation
import NovelForgeCore
import ShadowDesignSystem
import SwiftUI

nonisolated enum FindingState: Equatable, Sendable {
  case open
  case fixing
  case settled
}

nonisolated struct FindingGroup: Equatable, Sendable {
  let severity: StoredEnum<ReviewFindingSeverity>
  let findings: [ReviewFinding]
}

nonisolated enum ReviewJobPhase: Equatable, Sendable {
  /// Who a queued review waits for, from its job line: an iPhone or iPad never starts a review it was not told to run.
  enum Wait: Equatable, Sendable {
    /// This device's runtime starts it with nobody asking.
    case startsHere
    case permission
    /// Another device, or Run here or Resume on this one.
    case elsewhere
  }

  case queued(Wait)
  case running

  var isQueued: Bool {
    guard case .queued = self else { return false }
    return true
  }
}

/// apps/novel-forge-web/src/lib/chapter-checks.ts:1-330 and features/chapter-workspace/ChecksPanel.tsx.
enum ChecksDisplay {
  static let kinds = ChapterReviews.kindOrder

  static func isModelKind(_ kind: ChapterReviewKind) -> Bool { kind == .judge || kind == .editorial }

  static func label(_ kind: ChapterReviewKind) -> String {
    switch kind {
    case .judge: String(localized: "AI review", table: "Checks")
    case .editorial: String(localized: "Editor's read", table: "Checks")
    case .mechanics: String(localized: "Mechanics", table: "Checks")
    case .readability: String(localized: "Readability", table: "Checks")
    }
  }

  static func noun(_ kind: ChapterReviewKind) -> String {
    switch kind {
    case .judge: String(localized: "AI review", table: "Checks")
    case .editorial: String(localized: "editor's read", table: "Checks")
    case .mechanics: String(localized: "mechanics check", table: "Checks")
    case .readability: String(localized: "readability check", table: "Checks")
    }
  }

  static func description(_ kind: ChapterReviewKind) -> String {
    switch kind {
    case .judge: String(localized: "Reads the chapter against the Story Bible, the plan, the ending it should reach and the secrets kept from the reader.", table: "Checks")
    case .editorial:
      String(
        localized:
          "An editor's read against the plan, the canon and your style, with proofreading: grammar, spelling, punctuation, tense and point-of-view slips, names and references.",
        table: "Checks")
    case .mechanics:
      String(localized: "Length against the target, repeated paragraphs, reused phrases, stock phrases and dialogue tags. Measured at once, no model call.", table: "Checks")
    case .readability: String(localized: "Sentence and paragraph length, reading grade and ornate phrasing. Measured at once, no model call.", table: "Checks")
    }
  }

  static func runLabel(_ kind: ChapterReviewKind, hasReview: Bool) -> String {
    hasReview ? String(localized: "Run a New Review", table: "Checks") : String(localized: "Run the \(noun(kind))", table: "Checks")
  }

  static func severityLabel(_ severity: StoredEnum<ReviewFindingSeverity>) -> String {
    switch severity {
    case .known(.blocking): String(localized: "Blocking", table: "Checks")
    case .known(.warning): String(localized: "Warning", table: "Checks")
    case .known(.note): String(localized: "Note", table: "Checks")
    case .unknown(let raw): raw
    }
  }

  static func groupLabel(_ severity: StoredEnum<ReviewFindingSeverity>, count: Int) -> String {
    switch severity {
    case .known(.blocking): String(localized: "Blocking · \(count)", table: "Checks")
    case .known(.warning): String(localized: "Warnings · \(count)", table: "Checks")
    case .known(.note): String(localized: "Notes · \(count)", table: "Checks")
    case .unknown(let raw): "\(raw) · \(count)"
    }
  }

  static func severityIntent(_ severity: StoredEnum<ReviewFindingSeverity>) -> ShadowBadgeIntent {
    switch severity {
    case .known(.blocking): .danger
    case .known(.warning): .warning
    case .known(.note), .unknown: .neutral
    }
  }

  static func categoryLabel(_ category: StoredEnum<ReviewFindingCategory>) -> String {
    switch category {
    case .known(.continuity): String(localized: "Continuity", table: "Checks")
    case .known(.brief): String(localized: "The plan", table: "Checks")
    case .known(.ending): String(localized: "The ending", table: "Checks")
    case .known(.knowledge): String(localized: "Secrets", table: "Checks")
    case .known(.readability): String(localized: "Readability", table: "Checks")
    case .known(.mechanics): String(localized: "Mechanics", table: "Checks")
    case .known(.editorial): String(localized: "Editorial", table: "Checks")
    case .known(.proofreading): String(localized: "Proofreading", table: "Checks")
    case .unknown(let raw): raw
    }
  }

  static func groups(_ findings: [ReviewFinding]) -> [FindingGroup] {
    let known: [StoredEnum<ReviewFindingSeverity>] = [.known(.blocking), .known(.warning), .known(.note)]
    let others = findings.map(\.severity).filter { !known.contains($0) }
    var seen = Set<StoredEnum<ReviewFindingSeverity>>()
    return (known + others).filter { seen.insert($0).inserted }.compactMap { severity in
      let matching = findings.filter { $0.severity == severity }
      return matching.isEmpty ? nil : FindingGroup(severity: severity, findings: matching)
    }
  }

  static func state(_ remedy: ReviewRemedy?) -> FindingState {
    guard let remedy else { return .open }
    switch remedy.action {
    case .known(.fixingMyself): return .fixing
    case .known(.dismissed), .known(.overridden): return .settled
    case .unknown: return .open
    }
  }

  static func remedyNote(_ remedy: ReviewRemedy, severity: StoredEnum<ReviewFindingSeverity>) -> String {
    let reason = remedy.reason?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    switch remedy.action {
    case .known(.fixingMyself) where severity == .known(.blocking):
      return String(localized: "You'll fix it yourself — it still holds the next chapter until a new review finds it fixed", table: "Checks")
    case .known(.fixingMyself): return String(localized: "You'll fix it yourself — rechecked on the next review", table: "Checks")
    case .known(.overridden):
      guard let reason else { return String(localized: "Overridden — recorded as intended for this text", table: "Checks") }
      return String(localized: "Overridden: \(reason) — recorded as intended for this text", table: "Checks")
    case .known(.dismissed):
      guard let reason else { return String(localized: "Dismissed — won't be raised again for this text", table: "Checks") }
      return String(localized: "Dismissed: \(reason) — won't be raised again for this text", table: "Checks")
    case .unknown: return String(localized: "Answered in a form this version does not understand", table: "Checks")
    }
  }

  static func staleNotice() -> String {
    String(localized: "The chapter has changed since this review. Its findings describe the older text.", table: "Checks")
  }

  static func subline(_ review: ChapterReviewView?) -> String {
    guard let review else { return String(localized: "Not run yet", table: "Checks") }
    return review.stale ? String(localized: "Reviewed an earlier version", table: "Checks") : String(localized: "Reviewed the current text", table: "Checks")
  }

  static func status(_ review: ChapterReviewView?, job: ReviewJobPhase?) -> (label: String, intent: ShadowBadgeIntent) {
    if job == .running { return (String(localized: "Reviewing…", table: "Checks"), .info) }
    if job?.isQueued == true { return (String(localized: "Queued", table: "Checks"), .info) }
    guard let review else { return (String(localized: "Not run", table: "Checks"), .neutral) }
    if review.review.disposition == .known(.failed) { return (String(localized: "Not assessed", table: "Checks"), .neutral) }
    if review.stale { return (String(localized: "Out of date", table: "Checks"), .warning) }
    if review.openBlocking > 0 { return (String(localized: "\(review.openBlocking) blocking", table: "Checks"), .danger) }
    if review.openFindings > 0 { return (String(localized: "\(review.openFindings) open", table: "Checks"), .warning) }
    return (String(localized: "No issue", table: "Checks"), .success)
  }

  static func disposition(_ review: ChapterReviewView) -> (label: String, intent: ShadowBadgeIntent) {
    if review.review.disposition == .known(.failed) { return (String(localized: "Not assessed", table: "Checks"), .neutral) }
    if review.openBlocking > 0 { return (String(localized: "Revision suggested", table: "Checks"), .danger) }
    if review.openFindings > 0 { return (String(localized: "Looks good · notes", table: "Checks"), .warning) }
    return (String(localized: "No issue detected", table: "Checks"), .success)
  }

  static func meta(_ review: ChapterReviewView) -> String {
    var parts = [String(localized: "Saved with the chapter", table: "Checks")]
    if review.review.reviewKind.known.map({ !isModelKind($0) }) == true { parts.append(String(localized: "measured, no model call", table: "Checks")) }
    if review.review.isolated { parts.append(String(localized: "isolated chapter", table: "Checks")) }
    parts.append(String(localized: "reviews never edit your text", table: "Checks"))
    return parts.joined(separator: " · ")
  }

  static func offersOverride(_ finding: ReviewFinding) -> Bool { finding.severity == .known(.blocking) }

  static func isAnswerable(_ review: ChapterReviewView) -> Bool { !review.stale }

  static func confirmsUndo(approved: Bool, kind: ChapterReviewKind, finding: ReviewFinding, remedy: ReviewRemedy?) -> Bool {
    approved && kind == .judge && offersOverride(finding) && state(remedy) == .settled
  }

  static func reviewJobs(_ lines: [ChapterJobLine]) -> [ChapterJobLine] { lines.filter { $0.kind == .review } }

  static func phase(_ lines: [ChapterJobLine], of kind: ChapterReviewKind) -> ReviewJobPhase? {
    let jobs = lines.filter { $0.kind == .review && $0.reviewKind == kind }
    if jobs.contains(where: \.isRunning) { return .running }
    if jobs.contains(where: { if case .queued(let wait) = $0.state { wait.starter == .here } else { false } }) { return .queued(.startsHere) }
    if jobs.contains(where: { $0.state == .waitingForConsent }) { return .queued(.permission) }
    if jobs.contains(where: \.isQueued) { return .queued(.elsewhere) }
    return nil
  }
}

extension String {
  nonisolated fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
