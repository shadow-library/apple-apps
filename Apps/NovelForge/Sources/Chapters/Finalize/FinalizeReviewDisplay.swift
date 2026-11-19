import Foundation
import NovelForgeCore
import ShadowCore
import ShadowDesignSystem

/// apps/novel-forge-web/src/lib/finalize-review.ts: the words and choices of the finalize review dialog.
enum FinalizeReviewDisplay {
  // finalize-review.ts:60
  static let autoKeepCategories: [FinalizeCategory] = [.appearance, .characterState, .relationship, .promise, .entity, .milestone]

  // finalize-review.ts:62-71
  static func category(_ category: FinalizeCategory?) -> String {
    switch category {
    case .entity?: String(localized: "New in the Story Bible", table: "Finalize")
    case .appearance?: String(localized: "Appeared", table: "Finalize")
    case .characterState?: String(localized: "Where they stand", table: "Finalize")
    case .relationship?: String(localized: "Relationship", table: "Finalize")
    case .promise?: String(localized: "Promise", table: "Finalize")
    case .knowledge?: String(localized: "Knows", table: "Finalize")
    case .milestone?: String(localized: "Milestone", table: "Finalize")
    case .summary?: String(localized: "Summary later chapters see", table: "Finalize")
    case nil: String(localized: "Unreadable update", table: "Finalize")
    }
  }

  // finalize-review.ts:73-82
  static func autoKeep(_ category: FinalizeCategory) -> String {
    switch category {
    case .entity: String(localized: "New world details", table: "Finalize")
    case .appearance: String(localized: "Appearances", table: "Finalize")
    case .characterState: String(localized: "Where people are", table: "Finalize")
    case .relationship: String(localized: "Relationships", table: "Finalize")
    case .promise: String(localized: "Promises that moved", table: "Finalize")
    case .knowledge: String(localized: "What characters learn", table: "Finalize")
    case .milestone: String(localized: "Planned milestones", table: "Finalize")
    case .summary: String(localized: "Bridge summaries", table: "Finalize")
    }
  }

  // finalize-review.ts:163-171
  static func tag(_ item: FinalizeReviewScreen.Item) -> (label: String, intent: ShadowBadgeIntent) {
    switch item.flag {
    case .unplannedDisclosure?: return (String(localized: "Unplanned disclosure", table: "Finalize"), .danger)
    case .missedMilestone?: return (String(localized: "Missed milestone", table: "Finalize"), .warning)
    case .unclaimedMilestone?: return (String(localized: "Unplanned milestone", table: "Finalize"), .warning)
    case .renamedRecord?: return (String(localized: "Renames a record", table: "Finalize"), .warning)
    case .reopenedPromise?: return (String(localized: "Reopens a promise", table: "Finalize"), .warning)
    case nil: break
    }
    if item.basis == .inferred && item.category != .summary { return (String(localized: "Interpretation", table: "Finalize"), .warning) }
    return (category(item.category), .accent)
  }

  // finalize-review.ts:174-185
  static func stakes(_ item: FinalizeReviewScreen.Item) -> String? {
    let list = item.dependents.joined(separator: ", ")
    switch item.flag {
    case .missedMilestone?:
      return item.dependents.isEmpty
        ? String(localized: "Keeping it locked means later chapters can't count on it.", table: "Finalize")
        : String(localized: "Keeping it locked leaves \(list) without the milestone it needs.", table: "Finalize")
    case .unplannedDisclosure?:
      return item.dependents.isEmpty
        ? String(localized: "A character learns something the plan keeps locked here.", table: "Finalize") : String(localized: "Still waiting on: \(list).", table: "Finalize")
    case .unclaimedMilestone?: return String(localized: "The plan doesn't claim this milestone for this chapter.", table: "Finalize")
    case .renamedRecord?: return String(localized: "The Story Bible already has this record under another name.", table: "Finalize")
    case .reopenedPromise?: return String(localized: "The Story Bible has this settled; keeping it opens it again.", table: "Finalize")
    case nil: return nil
    }
  }

  /// finalize-review.ts:188-192: an isolated chapter's excerpt arrives as the withheld placeholder, shown as it is and unquoted.
  static func evidence(_ evidence: String?) -> (label: String?, text: String)? {
    guard let evidence, !evidence.isEmpty else { return nil }
    if evidence.hasPrefix("[excerpt withheld") { return (nil, evidence) }
    return (String(localized: "From the chapter:", table: "Finalize"), "“\(evidence)”")
  }

  // finalize-review.ts:201-207
  static func decision(_ item: FinalizeReviewScreen.Item) -> String {
    if item.autoKept { return String(localized: "Kept automatically", table: "Finalize") }
    switch item.decision {
    case .kept?: return String(localized: "Kept", table: "Finalize")
    case .edited?: return String(localized: "Kept as edited", table: "Finalize")
    case .skipped?: return String(localized: "Skipped", table: "Finalize")
    case nil: return String(localized: "Needs your call", table: "Finalize")
    }
  }

  // finalize-review.ts:288-291
  static func finalizeTitle(kept: Int) -> String {
    kept == 0 ? String(localized: "Finalize Without Updates", table: "Finalize") : String(localized: "Finalize and Keep \(kept) Updates", table: "Finalize")
  }

  // finalize-review.ts:293-296
  static func keepAllTitle(_ routine: [FinalizeReviewScreen.Item]) -> String {
    if routine.contains(where: { $0.decision == nil }) { return String(localized: "Keep All", table: "Finalize") }
    return routine.contains { $0.decision == .skipped } ? String(localized: "All Answered", table: "Finalize") : String(localized: "All Kept", table: "Finalize")
  }

  // finalize-review.ts:311-315: the categories this review batched, plus any already on so it can be turned off.
  static func autoKeepChoices(routine: [FinalizeReviewScreen.Item], autoKeep: [FinalizeCategory]) -> [FinalizeCategory] {
    let shown = Set(routine.compactMap(\.category)).union(autoKeep)
    return autoKeepCategories.filter(shown.contains)
  }

  // finalize-review.ts:317-322
  static func toggled(_ current: [FinalizeCategory], _ category: FinalizeCategory, on: Bool) -> [FinalizeCategory] {
    var next = Set(current)
    if on { next.insert(category) } else { next.remove(category) }
    return autoKeepCategories.filter(next.contains)
  }

  /// finalize-review.ts:330-335 without the revision number: native revisions are content hashes.
  static func subtitle(open: Int) -> String {
    let ask = open == 0 ? String(localized: "Nothing needs your call.", table: "Finalize") : String(localized: "\(open) updates need your call.", table: "Finalize")
    let read = String(localized: "Read from the version you approved.", table: "Finalize")
    let skip = String(
      localized: "Skipping only means “don't record this”. It doesn't unsay what the reader saw; to change what happened, edit the chapter before finalizing.", table: "Finalize")
    return "\(read) \(ask) \(skip)"
  }

  /// finalize-review.service.ts:159-168: what the disclosure check found among the review's items.
  static func disclosures(_ items: [FinalizeReviewScreen.Item]) -> [String] {
    items.filter { $0.flag == .unplannedDisclosure }.map(\.claim)
  }

  /// The update's details as finalize applies them, by the fields an edit can change; an appearance or an unreadable update has none.
  static func details(of change: [String: JSONValue]) -> [(label: String, value: String)] {
    let record = FinalizeEditFields.record(of: change)
    return FinalizeEditFields.fields(of: change).compactMap { field in
      switch FinalizeEditFields.value(field, record.fields[field.key]) {
      case .flag(let on): (field.label, on ? String(localized: "Yes", table: "Finalize") : String(localized: "No", table: "Finalize"))
      case .text(let text): text.isEmpty ? nil : (field.label, text)
      }
    }
  }
}
