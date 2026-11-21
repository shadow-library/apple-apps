import Foundation
import ShadowCore

/// `quest-commands.service.ts`: quest CRUD, the occurrence actions and the log edits.
extension ReplayState {
  /// Command-layer policy rather than a versioned reward number, so these stay outside `Ruleset`, as in the reference.
  static let rescheduleCapPerWindow = 2
  static let rescheduleWindowDays = 7
  static let editWindowMillis: Int64 = 7 * ApplyContext.millisPerDay

  mutating func createQuest(_ creation: QuestCreation, in context: ApplyContext) -> ReplayOutcome {
    guard quests[creation.questId] == nil else { return .superseded }
    questCount += 1
    earliestQuestDay = min(context.accountDay, earliestQuestDay ?? context.accountDay)
    quests[creation.questId] = ReplayQuest(id: creation.questId, schedule: creation.schedule, createdOrder: questCount, createdOn: context.accountDay)
    claimPendingReturnerShield(for: creation.questId, on: context.accountDay, ruleset: context.ruleset)
    return .applied
  }

  mutating func updateQuest(_ update: QuestUpdate) throws(ReplayRefusal) -> ReplayOutcome {
    guard var quest = quests[update.questId] else { throw .questNotFound }
    try quest.apply(update.patch)
    quests[update.questId] = quest
    return .applied
  }

  mutating func deleteQuest(_ reference: QuestReference) throws(ReplayRefusal) -> ReplayOutcome {
    guard var quest = quests[reference.questId] else { throw .questNotFound }
    quest.deactivate()
    quests[reference.questId] = quest
    return .applied
  }

  mutating func resolveCompletion(_ occurrence: Occurrence, _ completion: CompletionKind, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let ruleset = context.ruleset
    let quest = try occurringQuest(occurrence)
    try assertBegun(occurrence, in: context)
    let schedule = quest.schedule
    let band = ruleset.timingBand(
      for: TimingBandInput(
        strictness: schedule.strictness, startMinute: schedule.startTimeMinutes, durationMinutes: schedule.durationMinutes,
        daysElapsed: context.issuedOn.days(since: occurrence.date), minuteOfDay: context.minuteOfDay))
    let state: QuestLogState = completion == .partial ? .partial : band == .onTime ? .completed : .late

    let intensityMode = intensityMode(for: occurrence.date, accountDay: context.accountDay)
    let prior = streak(of: quest.id)
    let transition = ruleset.applyStreakEvent(
      StreakEvent(state: state, strictness: schedule.strictness, intensityMode: intensityMode, streakOptIn: schedule.optionalStreakOptIn, onTime: band == .onTime),
      to: prior)
    let postStreakDays = transition.outcome == .neutral ? prior.currentDays : transition.state.currentDays

    let day = days[occurrence.date]
    let lockActive = day?.lockBonusApplies(to: quest.id) ?? false
    let fire = day.flatMap { Self.comebackFire(on: $0, for: schedule.strictness, ruleset: ruleset) }
    let rewardInput = RewardInput(
      strictness: schedule.strictness, band: band, completion: completion, streakDays: postStreakDays, lockActive: lockActive, oneShot: .none)
    var claimed = rewardInput
    claimed.oneShot = fire == nil ? .none : .comeback
    let reward = ruleset.reward(for: claimed)

    let write = QuestLogWrite(
      id: context.id, state: state, xpAwarded: reward.xp, coinsAwarded: reward.coins, statAffinity: schedule.statAffinity, strictness: schedule.strictness,
      intensityModeAtLog: intensityMode, crownSliceWeight: ruleset.crownWeight(for: schedule.strictness), rulesetVersion: ruleset.version,
      performedAtMillis: context.instant, atMillis: context.instant)
    guard let log = upsertTerminal(write, at: occurrence) else { return .superseded }
    applyStreakTransition(transition, quest: quest.id, date: occurrence.date)

    let type: HeroEventType = completion == .partial ? .questPartial : band == .onTime ? .questComplete : .questLate
    _ = hero.credit(
      [
        GrantIntent(
          key: "\(log.id.lowercasedString)_xp", type: type, date: occurrence.date, xpDelta: reward.xp, coinsDelta: reward.coins, statAffinity: schedule.statAffinity,
          statDelta: reward.statTick, quest: quest.id, log: log.id, state: state)
      ], ruleset: ruleset)
    onQuestCompletion(
      date: occurrence.date, strictness: schedule.strictness, priorStreakDays: prior.currentDays, postStreakDays: postStreakDays, ruleset: ruleset)

    if let fire {
      recordComebackFire(fire, on: occurrence.date, consumedLog: log.id, intensityMode: intensityMode, claimed: rewardInput, in: context)
      onComebackBonusClaimed(date: occurrence.date, ruleset: ruleset)
    }
    return .applied
  }

  mutating func resolveBreak(_ action: QuestBreak, _ state: QuestLogState, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let ruleset = context.ruleset
    let occurrence = action.occurrence
    let quest = try occurringQuest(occurrence)
    let schedule = quest.schedule
    if state == .postponed && !ruleset.strictness[schedule.strictness].allowsPostpone { throw .postponeUnavailable }
    try assertBegun(occurrence, in: context)

    let intensityMode = intensityMode(for: occurrence.date, accountDay: context.accountDay)
    let transition = ruleset.applyStreakEvent(
      StreakEvent(state: state, strictness: schedule.strictness, intensityMode: intensityMode, streakOptIn: schedule.optionalStreakOptIn, onTime: false),
      to: streak(of: quest.id))
    let reasonNote = action.hasNote ? context.id : nil
    let write = QuestLogWrite(
      id: context.id, state: state, statAffinity: schedule.statAffinity, strictness: schedule.strictness, intensityModeAtLog: intensityMode,
      crownSliceWeight: ruleset.crownWeight(for: schedule.strictness), rulesetVersion: ruleset.version, reasonTag: action.reasonTag, reasonNote: reasonNote,
      postponedToDate: state == .postponed ? occurrence.date.adding(days: 1) : nil, atMillis: context.instant)
    guard upsertTerminal(write, at: occurrence) != nil else { return .superseded }
    applyStreakTransition(transition, quest: quest.id, date: occurrence.date)
    if action.reasonTag != nil || action.hasNote { onReasonTagged(date: occurrence.date, ruleset: ruleset) }
    resettleOpenDayCrown(on: occurrence.date, ruleset: ruleset)

    if state == .postponed, var day = days[occurrence.date], day.isOpen, day.lockBonusApplies(to: quest.id) {
      day.lock?.brokenAtMillis = context.instant
      days[occurrence.date] = day
    }
    return .applied
  }

  /// Past the cap, an accepted reschedule becomes a postpone and an unaccepted one is handed back to the owner.
  mutating func reschedule(_ action: QuestReschedule, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    let ruleset = context.ruleset
    let occurrence = action.occurrence
    let quest = try occurringQuest(occurrence)
    let schedule = quest.schedule
    if ruleset.strictness[schedule.strictness].schedulingModel == .dayLevel { throw .rescheduleUnavailable }

    let window = (0..<Self.rescheduleWindowDays).compactMap { occurrence.date.adding(days: -$0) }
    let used = window.count { reschedules[Occurrence(quest: quest.id, date: $0)] != nil }
    if used >= Self.rescheduleCapPerWindow {
      guard action.acceptBeyondCap else { return .rejected(.rescheduleCap) }
      return try resolveBreak(QuestBreak(occurrence: occurrence, reasonTag: action.reasonTag, hasNote: action.hasNote), .postponed, in: context)
    }

    guard reschedules[occurrence] == nil else { throw .alreadyRescheduled }
    let reasonNote = action.hasNote ? context.id : nil
    let entry = RescheduleEntry(fromMinute: schedule.startTimeMinutes, toMinute: action.toMinute, reasonTag: action.reasonTag, reasonNote: reasonNote)
    reschedules[occurrence] = entry
    if entry.hasReason { reasonedReschedules[occurrence.date, default: 0] += 1 }
    let write = QuestLogWrite(
      id: context.id, state: .rescheduled, statAffinity: schedule.statAffinity, strictness: schedule.strictness,
      intensityModeAtLog: settings.intensityMode(on: context.accountDay), crownSliceWeight: ruleset.crownWeight(for: schedule.strictness),
      rulesetVersion: ruleset.version, rescheduledToMinute: action.toMinute, atMillis: context.instant)
    guard upsertReschedule(write, at: occurrence) != nil else { return .superseded }
    if action.reasonTag != nil || action.hasNote {
      onReasonTagged(date: occurrence.date, ruleset: ruleset)
      onRescheduleReasonLogged(date: occurrence.date, ruleset: ruleset)
    }
    return .applied
  }

  /// Sets both the tag and the note, so attaching one clears the other, as the reference's repository writes both.
  mutating func attachReason(_ reason: QuestReason, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    var log = try editableLog(reason.occurrence, in: context)
    log.reasonTag = reason.reasonTag
    log.reasonNote = reason.hasNote ? context.id : nil
    logs[reason.occurrence] = log
    onReasonTagged(date: reason.occurrence.date, ruleset: context.ruleset)
    return .applied
  }

  mutating func editLog(_ edit: QuestLogEdit, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    var log = try editableLog(edit.occurrence, in: context)
    switch edit.reasonTag {
    case .keep: break
    case .clear: log.reasonTag = nil
    case .set(let tag): log.reasonTag = tag
    }
    switch edit.note {
    case .keep: break
    case .clear: log.reasonNote = nil
    case .set: log.reasonNote = context.id
    }
    switch edit.reflection {
    case .keep: break
    case .clear: log.reflection = nil
    case .set: log.reflection = context.id
    }
    logs[edit.occurrence] = log
    return .applied
  }

  /// Deletion has no time window and never touches the hero trail.
  mutating func deleteLog(_ occurrence: Occurrence, in context: ApplyContext) throws(ReplayRefusal) -> ReplayOutcome {
    guard logs.removeValue(at: occurrence) != nil else { throw .logNotFound }
    resettleOpenDayCrown(on: occurrence.date, ruleset: context.ruleset)
    return .applied
  }

  /// A Returner shield waiting for a quest goes to the first one created after it.
  mutating func claimPendingReturnerShield(for quest: UUID, on date: LocalDate, ruleset: Ruleset) {
    guard compassion.pendingReturnerShields > 0 else { return }
    let granted = ruleset.grantStreakShields(compassion.pendingReturnerShields, to: .empty)
    compassion.pendingReturnerShields = 0
    writeStreak(granted.state, quest: quest, date: date)
  }

  private func occurringQuest(_ occurrence: Occurrence) throws(ReplayRefusal) -> ReplayQuest {
    guard let quest = quests[occurrence.quest], quest.isActive else { throw .questNotFound }
    guard recurrenceCursors.occurs(quest, on: occurrence.date) else { throw .noOccurrence(occurrence.date) }
    return quest
  }

  /// An outcome for a day that had not begun when the command was issued is refused; a past day's is how an offline completion arrives.
  private func assertBegun(_ occurrence: Occurrence, in context: ApplyContext) throws(ReplayRefusal) {
    if occurrence.date > context.latestBegunDay(openDay: openDay) { throw .notStarted(occurrence.date) }
  }

  /// The edit window runs from the log's recorded instant to the command's, never the device clock.
  private func editableLog(_ occurrence: Occurrence, in context: ApplyContext) throws(ReplayRefusal) -> QuestLogEntry {
    guard let log = logs[occurrence] else { throw .logNotFound }
    if context.instant - log.createdAtMillis > Self.editWindowMillis { throw .editWindowClosed }
    return log
  }

  private static func comebackFire(on day: ReplayDay, for strictness: Strictness, ruleset: Ruleset) -> ComebackFire? {
    guard day.isOpen, day.comeback.armed, ruleset.canFireComeback(day.comeback, on: strictness) else { return nil }
    return ruleset.fireComeback(day.comeback, on: strictness)
  }

  private mutating func recordComebackFire(
    _ fire: ComebackFire, on date: LocalDate, consumedLog: UUID, intensityMode: IntensityMode, claimed: RewardInput, in context: ApplyContext
  ) {
    guard var day = days[date] else { return }
    let bonus = context.ruleset.comebackBonus(claimed: claimed)
    let kind: ComebackEventKind = fire.kind == .reFired ? .reFired : .fired
    day.record(
      ComebackEvent(kind: kind, trigger: nil, sourceLog: nil, consumedLog: consumedLog, xpBonus: bonus.xp, coinBonus: bonus.coins, intensityMode: intensityMode))
    if day.isOpen {
      day.comeback = fire.state
      day.comebackFiredAtMillis = day.comebackFiredAtMillis ?? context.instant
    }
    days[date] = day
  }

}
