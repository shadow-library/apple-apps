import Foundation
import MemoirCore

/// Coming back's headline and body for its reason (`synced-hero-provider.ts:84-130`, `labels.ts:13-22`).
nonisolated struct ComingBackCopy: Equatable {
  let headline: String
  let body: String

  init(reason: ComingBackReason?, claimed: Bool) {
    switch reason {
    case .returner?:
      headline = String(localized: "Welcome back", table: "Hero")
      body = String(
        localized:
          "You have been away for a while. Your experience, levels and titles are untouched, and streaks that closed while you were gone keep their records in History.",
        table: "Hero")
    case .recovery?:
      headline = String(localized: "A recovery quest is on today", table: "Hero")
      body = String(
        localized:
          "A quest was missed yesterday, so today also offers a lighter recovery quest you can keep before the day closes. Nothing you have earned was taken away.",
        table: "Hero")
    case .comeback? where claimed:
      headline = String(localized: "Comeback bonus claimed", table: "Hero")
      body = String(
        localized: "You kept a quest after recent misses today, and the comeback bonus was added to it. There is nothing else to do.", table: "Hero")
    case .comeback?:
      headline = String(localized: "A comeback bonus is ready", table: "Hero")
      body = String(localized: "After recent misses, the next anchor or routine quest you keep today earns extra experience and a coin.", table: "Hero")
    case nil:
      headline = String(localized: "Nothing to come back from", table: "Hero")
      body = String(
        localized: "Nothing is waiting for you here today. After a missed day or a break, this page shows what changed and the choices open to you.",
        table: "Hero")
    }
  }

  /// `missedRecently` (`synced-hero-provider.ts:189-201`).
  static func missMeta(_ quest: RecentMisses) -> String {
    guard let last = quest.misses.last?.date else { return "" }
    let lastText = HeroDates.text(last, year: false)
    guard quest.misses.count > 1 else { return lastText }
    var parts = [String(localized: "\(quest.misses.count) misses", table: "Hero"), String(localized: "last \(lastText)", table: "Hero")]
    let shielded = quest.misses.count(where: \.shielded)
    if shielded > 0 { parts.append(String(localized: "\(shielded) shielded", table: "Hero")) }
    return parts.joined(separator: " · ")
  }
}

/// One open choice: what it is, what it does, and the screen that acts on it.
struct ComingBackChoiceCopy {
  let title: String
  let body: String
  let effect: String
  let action: String
  let destination: MemoirDestination

  init(_ choice: ComingBackChoice, recovery: RecoveryOffer?) {
    let anyQuest = String(localized: "Pick whichever quest on today’s list feels manageable. There is nothing to catch up on.", table: "Hero")
    let asUsual = String(localized: "Grants experience as usual.", table: "Hero")
    let today = String(localized: "Go to today", table: "Hero")
    switch choice {
    case .keepOneQuestToday:
      self.init(title: String(localized: "Keep one quest today", table: "Hero"), body: anyQuest, effect: asUsual, action: today, destination: .today)
    case .keepRecoveryQuest:
      let body =
        recovery?.sourceName.map { String(localized: "The lighter version of \($0) is on today’s list and judged on the day rather than the hour.", table: "Hero") }
        ?? String(localized: "It is on today’s list and judged on the day rather than the hour.", table: "Hero")
      self.init(title: String(localized: "Keep the recovery quest", table: "Hero"), body: body, effect: asUsual, action: today, destination: .today)
    case .keepComebackQuest:
      self.init(
        title: String(localized: "Keep an anchor or routine quest", table: "Hero"), body: anyQuest,
        effect: String(localized: "Grants experience with the comeback bonus added.", table: "Hero"), action: today, destination: .today)
    case .reviewWeek:
      self.init(
        title: String(localized: "Look over the week", table: "Hero"), body: String(localized: "Moving or pausing a quest can make the coming days lighter.", table: "Hero"),
        effect: String(localized: "Nothing changes until you move or pause something.", table: "Hero"), action: String(localized: "See the week", table: "Hero"),
        destination: .planningBoard)
    }
  }

  private init(title: String, body: String, effect: String, action: String, destination: MemoirDestination) {
    self.title = title
    self.body = body
    self.effect = effect
    self.action = action
    self.destination = destination
  }
}
