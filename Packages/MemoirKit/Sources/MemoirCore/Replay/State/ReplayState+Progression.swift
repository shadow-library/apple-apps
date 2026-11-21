import Foundation

/// The reference's `ProgressionService` triggers: each folds one event into the counters, then checks both catalogues against the merged snapshot.
extension ReplayState {
  static let rescheduleReasonWindowDays = 90

  mutating func onQuestCompletion(date: LocalDate, strictness: Strictness, priorStreakDays: Int, postStreakDays: Int, ruleset: Ruleset) {
    let silver = ruleset.streakTierMinDays(.silver) ?? Int.max
    let reachedSilver = priorStreakDays < silver && postStreakDays >= silver
    let isNewActiveDay = progression.lastActiveCountedDate != date
    var counters = progression.counters
    counters.questsCompleted = Exact.adding(counters.questsCompleted, 1)
    counters.completionsByStrictness[strictness] = Exact.adding(counters.completionsByStrictness[strictness], 1)
    counters.longestStreakDays = max(counters.longestStreakDays, postStreakDays)
    if strictness == .anchor { counters.longestAnchorStreakDays = max(counters.longestAnchorStreakDays, postStreakDays) }
    if reachedSilver { counters.questsReachingSilverStreak = Exact.adding(counters.questsReachingSilverStreak, 1) }
    if progression.returnerPending { counters.completionsAfterReturner = Exact.adding(counters.completionsAfterReturner, 1) }
    if isNewActiveDay {
      counters.activeDays = Exact.adding(counters.activeDays, 1)
      progression.lastActiveCountedDate = date
    }
    progression.counters = counters
    progression.returnerPending = false
    evaluateProgress(on: date, ruleset: ruleset)
  }

  mutating func onSubscriptionConfirmed(date: LocalDate, ruleset: Ruleset) {
    count(\.subscriptionsConfirmed, on: date, ruleset: ruleset)
  }

  mutating func onReceiptScanned(date: LocalDate, ruleset: Ruleset) {
    count(\.receiptsScanned, on: date, ruleset: ruleset)
  }

  mutating func onCrownBanked(date: LocalDate, ruleset: Ruleset) {
    count(\.crownsBanked, on: date, ruleset: ruleset)
  }

  /// A full HP day has at least one scheduled occurrence and no miss.
  mutating func onDayClosed(date: LocalDate, scheduledCount: Int, missedCount: Int, ruleset: Ruleset) {
    guard scheduledCount > 0, missedCount == 0 else { return }
    count(\.fullHPDays, on: date, ruleset: ruleset)
  }

  mutating func onReturnerFired(date: LocalDate, ruleset: Ruleset) {
    progression.returnerPending = true
    count(\.returnerRitualsCompleted, on: date, ruleset: ruleset)
  }

  mutating func onReasonTagged(date: LocalDate, ruleset: Ruleset) {
    count(\.reasonTaggedEvents, on: date, ruleset: ruleset)
  }

  /// The 90-day window is not a lifetime count, so a reasoned reschedule only re-evaluates.
  mutating func onRescheduleReasonLogged(date: LocalDate, ruleset: Ruleset) {
    evaluateProgress(on: date, ruleset: ruleset)
  }

  mutating func onRecoveryQuestCompleted(date: LocalDate, ruleset: Ruleset) {
    progression.counters.completionsByStrictness[.recovery] = Exact.adding(progression.counters.completionsByStrictness[.recovery], 1)
    evaluateProgress(on: date, ruleset: ruleset)
  }

  mutating func onComebackBonusClaimed(date: LocalDate, ruleset: Ruleset) {
    count(\.comebackBonusesClaimed, on: date, ruleset: ruleset)
  }

  mutating func onLockedDayCleared(date: LocalDate, ruleset: Ruleset) {
    count(\.lockedDaysCleared, on: date, ruleset: ruleset)
  }

  /// The counters the catalogues read on `date`: the stored ones, the ledger's totals and the reasoned reschedules of the 90 days ending on it.
  public func progressSnapshot(on date: LocalDate) -> ProgressCounters {
    var snapshot = progression.counters
    snapshot.totalXP = hero.totalXP
    snapshot.level = hero.level
    snapshot.stats = hero.stats
    snapshot.reschedulesWithReasonIn90Days = Exact.sum((0..<Self.rescheduleReasonWindowDays).compactMap { date.adding(days: -$0) }.map { reasonedReschedules[$0] ?? 0 })
    return snapshot
  }

  /// Grants every achievement and title the snapshot newly satisfies; an achievement also lands on the hero trail and unlocks its cosmetics.
  mutating func evaluateProgress(on date: LocalDate, ruleset: Ruleset) {
    let snapshot = progressSnapshot(on: date)
    for achievement in ruleset.unlockedAchievements(snapshot, earned: Array(progression.achievements.keys)) {
      progression.achievements[achievement] = date
      _ = hero.credit([GrantIntent(key: "achievement:\(achievement.rawValue)", type: .achievementUnlock, date: date, achievement: achievement)], ruleset: ruleset)
      for cosmetic in CosmeticID.allCases where cosmetic.unlockedBy == achievement && progression.cosmetics[cosmetic] == nil {
        progression.cosmetics[cosmetic] = OwnedCosmetic(source: .achievement, equipped: false)
      }
    }
    for title in ruleset.unlockedTitles(snapshot, earned: Array(progression.titles.keys)) { progression.titles[title] = date }
  }

  private mutating func count(_ counter: WritableKeyPath<ProgressCounters, Int>, on date: LocalDate, ruleset: Ruleset) {
    progression.counters[keyPath: counter] = Exact.adding(progression.counters[keyPath: counter], 1)
    evaluateProgress(on: date, ruleset: ruleset)
  }
}
