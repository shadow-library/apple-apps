import Foundation
import ShadowCore

/// `RolloverService.prepareToday`: the day the walk reaches opens under the settings in force on it (`ReplaySettings` has already promoted a time zone or
/// intensity change whose first day it is), then the Returner, Comeback and Recovery read the days before it, and its HP and Crown are set for the day.
extension ReplayState {
  static let recoveryQuestDomain = "com.shadow.library.memoircore.recovery-quest"
  static let momentumRecentDays = 3
  /// Longer than any streak the milestone tiers name, as the reference's Returner looks back for the run before the absence.
  static let preAbsenceLookbackDays = 400

  mutating func prepareDay(_ date: LocalDate, driver: WalkDriver) {
    let ruleset = driver.ruleset
    let mode = settings.intensityMode(on: date)
    openDay = date
    let history = logs.unorderedEntries(from: date.adding(days: -ruleset.momentum.medianWindowDays) ?? .earliest, through: date)
    let todayLogs = insertionOrdered(logs.unorderedEntries(on: date))
    let momentum = ruleset.momentum(
      for: MomentumInput(
        recentCompletions: Self.holdCounts(in: history, endingOn: date, days: Self.momentumRecentDays),
        trailingCompletions: Self.holdCounts(in: history, endingOn: date, days: ruleset.momentum.medianWindowDays)))

    let returner = fireReturner(on: date, mode: mode, ruleset: ruleset)
    let recentMisses = history.filter { $0.value.state == .missed }.map { RecentMiss(daysAgo: date.days(since: $0.occurrence.date), strictness: $0.value.strictness) }
    let arming = ruleset.comebackArming(
      for: ComebackArmingInput(intensityMode: mode, momentum: momentum.bucket, returnerFired: returner, recentMisses: recentMisses.filter { $0.daysAgo >= 1 }))
    spawnRecovery(on: date, returner: returner, driver: driver)

    var day = days[date] ?? ReplayDay(date: date, intensityMode: mode, rulesetVersion: ruleset.version)
    day.intensityMode = mode
    day.rulesetVersion = ruleset.version
    day.hp = dayHP(on: date, logs: todayLogs, mode: mode, ruleset: ruleset)
    if let period = ruleset.crownPeriod(ruleset.crownCadence(for: mode), containing: date) {
      let breaks = todayLogs.filter { $0.value.isBreak }.map(\.value.crownSliceWeight)
      let state = ruleset.recomputeCrownDay(weights: walkScheduledQuests(on: date).map { ruleset.crownWeight(for: $0.schedule.strictness) }, forfeited: breaks)
      day.crown = DayCrown(state: state, periodStart: period.start, banked: nil)
    }
    day.comeback = ComebackDayState(armed: arming.isArmed, fires: day.comeback.fires, armedViaRecovery: day.comeback.armedViaRecovery)
    if arming.isArmed {
      day.record(ComebackEvent(kind: .armed, trigger: arming.trigger, sourceLog: nil, consumedLog: nil, xpBonus: 0, coinBonus: 0, intensityMode: mode))
    }
    day.returnerActive = returner
    day.returnerFired = returner
    day.momentum = momentum.bucket
    day.missedCount = todayLogs.count { $0.value.state == .missed }
    days[date] = day
    if todayLogs.contains(where: { $0.value.isHold }), compassion.lastActiveDate.map({ $0 < date }) ?? true { compassion.lastActiveDate = date }
  }

  /// Hold-state counts by days before `date`, most recent first.
  private static func holdCounts(in history: [(occurrence: Occurrence, value: QuestLogEntry)], endingOn date: LocalDate, days: Int) -> [Int] {
    var counts = Array(repeating: 0, count: max(0, days))
    for entry in history where entry.value.isHold {
      let offset = date.days(since: entry.occurrence.date)
      if offset >= 0 && offset < counts.count { counts[offset] += 1 }
    }
    return counts
  }

  /// The Returner fires once per day after an absence of the threshold's length; its shield goes to the quest with the longest run before the absence,
  /// or waits for the next quest created. Only an account that has once been active on a quest can return; under money rules its money activity
  /// counts as presence too, while the shield still follows the quests alone.
  private mutating func fireReturner(on date: LocalDate, mode: IntensityMode, ruleset: Ruleset) -> Bool {
    guard let questActive = compassion.lastActiveDate else { return false }
    let lastActive = ruleset.money == nil ? questActive : max(questActive, money.lastActivityDay ?? questActive)
    let daysAbsent = date.days(since: lastActive)
    guard ruleset.returnerFires(daysSinceLastActivity: daysAbsent, thresholdDays: settings.returnerThresholdDays(on: date)) else { return false }
    let plan = ruleset.planReturnerShieldGrant(returnerCandidates(lastActive: questActive))
    guard compassion.returnerEvents[date] == nil else { return true }
    let target = plan.questID.flatMap(UUID.init(uuidString:))
    var shieldPending = true
    if case .granted = plan.placement { shieldPending = false }
    compassion.returnerEvents[date] = ReturnerEvent(
      date: date, lastActiveDate: lastActive, daysAbsent: daysAbsent, shieldTarget: target, shieldPending: shieldPending, intensityMode: mode)
    if let target {
      writeStreak(ruleset.grantStreakShields(plan.shields, to: streak(of: target)).state, quest: target, date: date)
    } else {
      compassion.pendingReturnerShields = Exact.adding(compassion.pendingReturnerShields, plan.shields)
    }
    _ = hero.credit([GrantIntent(key: "returner_\(date)", type: .returnerFired, date: date)], ruleset: ruleset)
    onReturnerFired(date: date, ruleset: ruleset)
    return true
  }

  /// The run each active quest held up to the last active day, counted back from it rather than read off the streaks the absence has broken.
  private func returnerCandidates(lastActive: LocalDate) -> [ReturnerCandidate] {
    quests.values.filter(\.isActive).compactMap { quest in
      var run = 0
      while run <= Self.preAbsenceLookbackDays, let day = lastActive.adding(days: -run), logs[Occurrence(quest: quest.id, date: day)]?.isHold == true { run += 1 }
      guard run > 0 else { return nil }
      return ReturnerCandidate(questID: quest.id.uuidString, preAbsenceStreakDays: run, createdOrder: quest.createdOrder, shields: streak(of: quest.id).shields)
    }
  }

  /// One Recovery quest a day, after yesterday's misses of the strictness levels that trigger one, aimed at the heaviest of them; a missed Recovery quest
  /// is never scheduled, so it never spawns another.
  private mutating func spawnRecovery(on date: LocalDate, returner: Bool, driver: WalkDriver) {
    let ruleset = driver.ruleset
    guard let yesterday = date.adding(days: -1) else { return }
    let triggers = insertionOrdered(logs.unorderedEntries(on: yesterday)).filter {
      $0.value.state == .missed && ruleset.recovery.triggeredByStrictness.contains($0.value.strictness)
    }
    guard var source = triggers.first, compassion.recoveries[date] == nil else { return }
    for entry in triggers.dropFirst() where entry.value.crownSliceWeight > source.value.crownSliceWeight { source = entry }
    let sourceQuest = quests[source.occurrence.quest].flatMap { $0.isActive ? $0.id : nil }
    let nextDayStart = date.adding(days: 1).map { Int64($0.daysSinceEpoch) * ApplyContext.millisPerDay - Int64(driver.utcOffsetMinutes) * ApplyContext.millisPerMinute }
    compassion.recoveries[date] = RecoveryQuest(
      id: derivedID(Self.recoveryQuestDomain, date.isoString), date: date, sourceQuest: sourceQuest, triggerLogs: triggers.map(\.value.id), isReturnerDay: returner,
      state: .pending, expiresAtMillis: nextDayStart)
    _ = hero.credit([GrantIntent(key: "recovery_spawned_\(date)", type: .recoverySpawned, date: date, quest: sourceQuest, log: source.value.id)], ruleset: ruleset)
  }
}
