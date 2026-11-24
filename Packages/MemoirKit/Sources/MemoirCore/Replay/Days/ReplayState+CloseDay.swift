import Foundation
import ShadowCore

/// `RolloverService.closeDay`: an elapsed day ends under the settings in force on it and the walk's ruleset. Every write goes through the natural key the
/// reference uses (a miss per occurrence, an expiry per Recovery quest, a Crown event per period or log), so a user's outcome for the occurrence still
/// replaces the miss afterwards, and HP charges each occurrence once.
extension ReplayState {
  static let missedLogDomain = "com.shadow.library.memoircore.missed-log"

  mutating func closeDay(_ date: LocalDate, driver: WalkDriver) {
    let existing = days[date]
    guard existing?.isClosed != true else { return }
    let ruleset = driver.ruleset
    let mode = settings.intensityMode(on: date)
    let scheduled = walkScheduledQuests(on: date)
    recordMisses(of: scheduled, on: date, mode: mode, driver: driver)
    expireRecoveries(through: date, ruleset: ruleset)

    let dayLogs = insertionOrdered(logs.unorderedEntries(on: date))
    let hp = dayHP(on: date, logs: dayLogs, mode: mode, ruleset: ruleset)
    let crown = settleCrown(on: date, scheduled: scheduled, logs: dayLogs, mode: mode, ruleset: ruleset)
    let missedCount = dayLogs.count { $0.value.state == .missed }
    var day = existing ?? ReplayDay(date: date, intensityMode: mode, rulesetVersion: ruleset.version)
    day.intensityMode = mode
    day.rulesetVersion = ruleset.version
    day.hp = hp
    day.crown = crown
    day.missedCount = missedCount
    day.isClosed = true
    days[date] = day

    onDayClosed(date: date, scheduledCount: scheduled.count, missedCount: missedCount, ruleset: ruleset)
    if Self.lockCleared(existing?.lock, logs: dayLogs) { onLockedDayCleared(date: date, ruleset: ruleset) }
    if dayLogs.contains(where: { $0.value.isHold }), compassion.lastActiveDate.map({ $0 < date }) ?? true { compassion.lastActiveDate = date }
    settleMoney(closing: date, ruleset: ruleset)
  }

  /// A scheduled occurrence nobody resolved is missed and breaks its streak, or uses a shield; an occurrence with any row keeps it.
  private mutating func recordMisses(of scheduled: [ReplayQuest], on date: LocalDate, mode: IntensityMode, driver: WalkDriver) {
    let ruleset = driver.ruleset
    for quest in scheduled {
      let occurrence = Occurrence(quest: quest.id, date: date)
      guard logs[occurrence] == nil else { continue }
      let schedule = quest.schedule
      logs[occurrence] =
        QuestLogWrite(
          id: derivedID(Self.missedLogDomain, "\(quest.id.lowercasedString)|\(date)"), state: .missed, statAffinity: schedule.statAffinity,
          strictness: schedule.strictness, intensityModeAtLog: mode, crownSliceWeight: ruleset.crownWeight(for: schedule.strictness),
          rulesetVersion: ruleset.version, atMillis: driver.instantMillis
        ).entry
      let transition = ruleset.applyStreakEvent(
        StreakEvent(state: .missed, strictness: schedule.strictness, intensityMode: mode, streakOptIn: schedule.optionalStreakOptIn, onTime: false),
        to: streak(of: quest.id))
      applyStreakTransition(transition, quest: quest.id, date: date)
    }
  }

  /// Bounded above only, so a Recovery quest on a day the catch-up limit skipped still expires at the next close; expiry is silent but leaves its event.
  private mutating func expireRecoveries(through date: LocalDate, ruleset: Ruleset) {
    let expiring = compassion.recoveries.values.filter { $0.date <= date && $0.state == .pending }.sorted { $0.date < $1.date }
    guard !expiring.isEmpty else { return }
    for recovery in expiring { compassion.recoveries[recovery.date]?.state = .expired }
    _ = hero.credit(
      expiring.map { GrantIntent(key: "recovery_expired_\($0.id.lowercasedString)", type: .recoveryExpired, date: date, quest: $0.sourceQuest) },
      ruleset: ruleset)
  }

  /// The day's Crown from its scheduled weight less each break's slice; a period's first day records its endowment, and its closing day banks every
  /// remainder of the period once, keyed by the period's start.
  private mutating func settleCrown(
    on date: LocalDate, scheduled: [ReplayQuest], logs dayLogs: [(occurrence: Occurrence, value: QuestLogEntry)], mode: IntensityMode, ruleset: Ruleset
  ) -> DayCrown? {
    let cadence = ruleset.crownCadence(for: mode)
    guard let period = ruleset.crownPeriod(cadence, containing: date) else { return nil }
    let forfeits = dayLogs.filter { $0.value.isBreak }
    let state = ruleset.recomputeCrownDay(
      weights: scheduled.map { ruleset.crownWeight(for: $0.schedule.strictness) }, forfeited: forfeits.map(\.value.crownSliceWeight))

    var intents = [GrantIntent]()
    if date == period.start && state.grantedXP + state.grantedCoins > 0 {
      intents.append(GrantIntent(key: "crowninit_\(period.start)", type: .crownInit, date: date))
    }
    for forfeit in forfeits {
      intents.append(
        GrantIntent(
          key: "crownforfeit_\(forfeit.value.id.lowercasedString)", type: .crownForfeit, date: date, quest: forfeit.occurrence.quest, log: forfeit.value.id,
          state: forfeit.value.state))
    }
    var banked: RewardAmount?
    if ruleset.isCrownPeriodClose(cadence, on: date) {
      let prior = (0..<max(0, date.days(since: period.start))).compactMap { period.start.adding(days: $0).flatMap { days[$0]?.crown?.state } }
      let amount = CrownDayState.bankAmount(prior + [state])
      banked = amount
      if amount.xp + amount.coins > 0 {
        intents.append(GrantIntent(key: "crownbanked_\(period.start)", type: .crownBanked, date: date, xpDelta: amount.xp, coinsDelta: amount.coins))
      }
    }
    if !intents.isEmpty { _ = hero.credit(intents, ruleset: ruleset) }
    if let banked, banked.xp + banked.coins > 0 { onCrownBanked(date: date, ruleset: ruleset) }
    return DayCrown(state: state, periodStart: period.start, banked: banked)
  }

  /// The lock survived the day unbroken and every quest it named ended in a hold state.
  private static func lockCleared(_ lock: DayLock?, logs dayLogs: [(occurrence: Occurrence, value: QuestLogEntry)]) -> Bool {
    guard let lock, lock.isActive, !lock.quests.isEmpty else { return false }
    let held = Set(dayLogs.filter { $0.value.isHold }.map(\.occurrence.quest))
    return lock.quests.allSatisfy(held.contains)
  }
}
