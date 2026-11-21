import Foundation

/// Everything replay derives from the command log: quests and their logs, the hero ledger, streaks, compassion mechanics, the settings in force,
/// each day's state, and what happened to every command. A pure value: the same ordered commands and records always give the same state.
///
/// Commands apply through `Replay.apply`; the day walk (closing days, misses, HP, Crown settlement, rollover) writes the same fields through the
/// internal operations below, which both share, as the reference's handlers and its rollover share one ledger and one log.
public struct ReplayState: Sendable, Hashable {
  public static let initial = ReplayState()

  public internal(set) var quests: [UUID: ReplayQuest] = [:]
  public internal(set) var logs = OccurrenceTable<QuestLogEntry>()
  public internal(set) var reschedules = OccurrenceTable<RescheduleEntry>()
  /// Reschedules with a reason by date, which the 90-day title window sums; a reschedule is never removed, so the counts only grow.
  public internal(set) var reasonedReschedules: [LocalDate: Int] = [:]
  public internal(set) var streaks: [UUID: QuestStreak] = [:]
  /// The occurrences a shield bridged, which the day's HP reads as shielded.
  public internal(set) var shieldConsumptions: Set<Occurrence> = []
  public internal(set) var hero = HeroLedger.empty
  public internal(set) var progression = ProgressionState.empty
  public internal(set) var compassion = CompassionState.empty
  public internal(set) var days: [LocalDate: ReplayDay] = [:]
  public internal(set) var settings = ReplaySettings.empty
  public internal(set) var records = RecordIndex.empty
  /// The day the account lives in, which the day walk advances; nil before it has opened one.
  public internal(set) var openDay: LocalDate?
  /// The latest `issuedOn` replay has seen, the day the walk closes up to.
  public internal(set) var latestIssuedOn: LocalDate?
  /// The highest ruleset version replay has seen; a day closes under it.
  public internal(set) var highestRulesetVersion: Int?
  public internal(set) var outcomes: [UUID: ReplayOutcome] = [:]
  public internal(set) var notices: [ReplayNotice] = []
  public internal(set) var halt: ReplayHalt?
  /// How many commands replay has taken in, refused ones included; the order of settings changes.
  public internal(set) var commandCount = 0
  public internal(set) var questCount = 0
  /// The account's day when its first quest was created, which with the earliest log bounds the days the lock capacity counts.
  public internal(set) var earliestQuestDay: LocalDate?

  public func streak(of quest: UUID) -> StreakState {
    streaks[quest]?.state ?? .empty
  }

  /// The account's day for a command: its zone's date, or the open day when a backward zone change left that ahead (`rules/time.ts:157-161`).
  public func accountDay(issuedOn: LocalDate) -> LocalDate {
    max(issuedOn, openDay ?? issuedOn)
  }

  /// The intensity mode an occurrence is judged under: its day's own, else the mode in force on the account's day.
  func intensityMode(for date: LocalDate, accountDay: LocalDate) -> IntensityMode {
    days[date]?.intensityMode ?? settings.intensityMode(on: accountDay)
  }

  /// Active quests other than Recovery ones scheduled on the day, as the day walk and the open-day Crown count them.
  public func scheduledQuests(on date: LocalDate) -> [ReplayQuest] {
    quests.values.filter { $0.isActive && $0.schedule.strictness != .recovery && $0.occurs(on: date) }.sorted { $0.createdOrder < $1.createdOrder }
  }
}

extension ReplayState {
  /// A fresh row always lands; an existing one takes the write only while it holds a yielding state. Nil means the occurrence converged on what was there.
  mutating func upsertTerminal(_ write: QuestLogWrite, at occurrence: Occurrence) -> QuestLogEntry? {
    guard let existing = logs[occurrence] else {
      logs[occurrence] = write.entry
      return write.entry
    }
    guard QuestLogEntry.yieldingStates.contains(existing.state) else { return nil }
    var replaced = existing
    replaced.state = write.state
    replaced.xpAwarded = write.xpAwarded
    replaced.coinsAwarded = write.coinsAwarded
    replaced.statAffinity = write.statAffinity
    replaced.strictness = write.strictness
    replaced.intensityModeAtLog = write.intensityModeAtLog
    replaced.crownSliceWeight = write.crownSliceWeight
    replaced.rulesetVersion = write.rulesetVersion
    replaced.reasonTag = write.reasonTag
    replaced.reasonNote = write.reasonNote
    replaced.rescheduledToMinute = write.rescheduledToMinute
    replaced.postponedToDate = write.postponedToDate
    replaced.performedAtMillis = write.performedAtMillis
    logs[occurrence] = replaced
    return replaced
  }

  /// A bare reschedule only ever replaces a system miss, never another reschedule or a real outcome.
  mutating func upsertReschedule(_ write: QuestLogWrite, at occurrence: Occurrence) -> QuestLogEntry? {
    guard let existing = logs[occurrence] else {
      logs[occurrence] = write.entry
      return write.entry
    }
    guard existing.state == .missed else { return nil }
    var replaced = existing
    replaced.state = .rescheduled
    replaced.rescheduledToMinute = write.rescheduledToMinute
    logs[occurrence] = replaced
    return replaced
  }

  /// A neutral transition writes nothing; a bridge records the shield it used at the occurrence.
  mutating func applyStreakTransition(_ transition: StreakTransition, quest: UUID, date: LocalDate) {
    guard transition.outcome != .neutral else { return }
    if transition.shieldsConsumed > 0 { shieldConsumptions.insert(Occurrence(quest: quest, date: date)) }
    writeStreak(transition.state, quest: quest, date: date)
  }

  /// `run_start_date` moves only when a fresh run starts and clears when the run ends.
  mutating func writeStreak(_ state: StreakState, quest: UUID, date: LocalDate) {
    guard var streak = streaks[quest] else {
      streaks[quest] = QuestStreak(state: state, runStartDate: state.currentDays > 0 ? date : nil, lastCountedDate: date)
      return
    }
    streak.state = state
    if state.currentDays == 0 { streak.runStartDate = nil }
    if state.currentDays == 1 { streak.runStartDate = date }
    streak.lastCountedDate = date
    streaks[quest] = streak
  }

  /// A break written into a still-open day forfeits its Crown slice at once; the endowment and the bank wait for the day's close.
  mutating func resettleOpenDayCrown(on date: LocalDate, ruleset: Ruleset) {
    guard var day = days[date], day.isOpen else { return }
    guard let period = ruleset.crownPeriod(ruleset.crownCadence(for: day.intensityMode), containing: date) else { return }
    let weights = scheduledQuests(on: date).map { ruleset.crownWeight(for: $0.schedule.strictness) }
    let forfeits = logs.entries(on: date).filter { $0.value.isBreak }.map(\.value.crownSliceWeight)
    day.crown = DayCrown(state: ruleset.recomputeCrownDay(weights: weights, forfeited: forfeits), periodStart: period.start, banked: day.crown?.banked)
    days[date] = day
  }
}
