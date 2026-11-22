import Foundation
import ShadowStore

/// What every quest read shares: the hero row and its open day, every quest replay knows with the owner's words for it, the open day's row and the
/// account settings. Read from the projection and the main store only, so no health- or activity-class value can reach a model built from it.
struct QuestReadContext {
  let hero: HeroSummaryRow?
  let quests: [QuestRow]
  let questsByID: [UUID: QuestRow]
  let records: [UUID: QuestRecord]
  let openDayRow: DayRow?
  let settings: AccountSettingsRecord?

  static func load(in transaction: ReadTransaction) throws(StoreError) -> QuestReadContext {
    let hero = try MemoirDerived.hero(in: transaction)
    let quests = try MemoirDerived.quests(in: transaction)
    var records = [UUID: QuestRecord]()
    for entry in try QuestRecord.listing(in: transaction).entries where !entry.isRemoved { records[entry.record.id] = entry.record }
    let openDayRow = try hero?.openDay.flatMap { day throws(StoreError) in try MemoirDerived.days(from: day, through: day, in: transaction).first }
    return QuestReadContext(
      hero: hero, quests: quests, questsByID: Dictionary(quests.map { ($0.id, $0) }) { first, _ in first }, records: records, openDayRow: openDayRow,
      settings: try AccountSettingsRecord.read(key: .accountSettings, in: transaction).entry?.record)
  }

  var openDay: LocalDate? { hero?.openDay }

  var ruleset: Ruleset { openDayRow.flatMap { Ruleset.version($0.rulesetVersion) } ?? .current }

  var activeQuests: [QuestRow] { quests.filter(\.schedule.active) }

  var scheduleWindow: ScheduleWindow { settings?.schedule ?? .standard }

  /// `weekStart` 0 is Sunday and anything else Monday, as the reference reads it (`lib/sync/projection.ts:458`).
  var weekStart: LocalDate.Weekday { settings?.weekStart == 0 ? .sunday : .monday }

  /// The day after the open day, when every day-relative read turns.
  var changesOn: LocalDate? { openDay?.adding(days: 1) }

  func relation(of date: LocalDate) -> DayRelation {
    guard let openDay else { return .today }
    if date < openDay { return .past }
    return date == openDay ? .today : .future
  }

  /// A day's row says the mode it was lived under; a later day takes the staged change, else the open day's mode.
  func intensityMode(on date: LocalDate, row: DayRow?) -> IntensityMode {
    if let row { return row.intensityMode }
    let current = openDayRow?.intensityMode ?? .standard
    guard let openDay, date > openDay else { return current }
    return hero?.pendingIntensityMode ?? current
  }

  func snapshot(_ quest: QuestRow) -> QuestSnapshot {
    let schedule = quest.schedule
    let record = records[quest.id]
    return QuestSnapshot(
      id: quest.id, name: record?.name, notes: record?.notes, strictness: schedule.strictness, statAffinity: schedule.statAffinity, startMinute: schedule.startTimeMinutes,
      durationMinutes: schedule.durationMinutes, recurrence: schedule.recurrence, recurrenceSummary: RecurrenceSummary(schedule.recurrence),
      moduleLink: schedule.moduleLink, optionalStreakOptIn: schedule.optionalStreakOptIn, isActive: schedule.active, createdOn: quest.createdOn,
      createdOrder: quest.createdOrder)
  }

  func streak(_ quest: QuestRow) -> StreakSummary {
    let schedule = quest.schedule
    return StreakSummary(
      currentDays: quest.streak.currentDays, longestDays: quest.streak.longestDays, shields: quest.streak.shields,
      completionsTowardShield: quest.streak.completionsTowardShield, pendingShieldGrant: quest.streak.pendingShieldGrant,
      isTracked: ruleset.streakApplies(to: schedule.strictness, optIn: schedule.optionalStreakOptIn), unit: schedule.recurrence.streakUnit,
      runStartDate: quest.runStartDate)
  }

  /// `true` when the open day's active lock names the quest.
  func isLockedToday(_ quest: UUID) -> Bool {
    guard let openDayRow, openDayRow.lock == .active else { return false }
    return openDayRow.lockQuests.contains(quest)
  }
}

/// The rows of a run of days, indexed, with each quest's recurrence expanded once over them; builds the occurrences of any day in the run.
struct OccurrenceSource {
  let context: QuestReadContext
  let from: LocalDate
  let through: LocalDate
  let logs: [LocalDate: [UUID: QuestLogRow]]
  let days: [LocalDate: DayRow]
  /// Each quest's reschedules from the week before `from` on.
  let rescheduled: [UUID: [LocalDate]]
  let reschedules: Set<Occurrence>
  let scheduled: [UUID: Set<LocalDate>]

  static func load(_ context: QuestReadContext, from: LocalDate, through: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> OccurrenceSource {
    var logs = [LocalDate: [UUID: QuestLogRow]]()
    for row in try MemoirDerived.questLogs(from: from, through: through, in: transaction) { logs[row.occurrence.date, default: [:]][row.occurrence.quest] = row }
    let days = Dictionary(try MemoirDerived.days(from: from, through: through, in: transaction).map { ($0.date, $0) }) { first, _ in first }
    let rescheduleRows = try MemoirDerived.reschedules(from: from.movedBy(days: -(RescheduleBudget.windowDays - 1)), through: .latest, in: transaction)
    var rescheduled = [UUID: [LocalDate]]()
    for row in rescheduleRows { rescheduled[row.occurrence.quest, default: []].append(row.occurrence.date) }
    var scheduled = [UUID: Set<LocalDate>]()
    for quest in context.quests {
      scheduled[quest.id] = Set(quest.schedule.recurrence.expand(from: from, through: through).occurrences.map(\.date))
    }
    return OccurrenceSource(
      context: context, from: from, through: through, logs: logs, days: days, rescheduled: rescheduled, reschedules: Set(rescheduleRows.map(\.occurrence)),
      scheduled: scheduled)
  }

  /// As `ReplayState.scheduledQuests(on:)`: active, not Recovery-strictness, and the recurrence lands on the day.
  func isScheduled(_ quest: QuestRow, on date: LocalDate) -> Bool {
    quest.schedule.active && quest.schedule.strictness != .recovery && scheduled[quest.id]?.contains(date) == true
  }

  /// The active quests scheduled on the day and any quest logged on it, by planned start (an all-day quest last) and then creation.
  func occurrences(on date: LocalDate) -> [BoardOccurrence] {
    let dayLogs = logs[date] ?? [:]
    let quests = context.quests.filter { isScheduled($0, on: date) || dayLogs[$0.id] != nil }
    return quests.map { occurrence(of: $0, on: date, log: dayLogs[$0.id]) }.sorted { first, second in
      let firstMinute = first.quest.startMinute ?? Self.allDay
      let secondMinute = second.quest.startMinute ?? Self.allDay
      return firstMinute != secondMinute ? firstMinute < secondMinute : first.quest.createdOrder < second.quest.createdOrder
    }
  }

  func occurrence(of quest: QuestRow, on date: LocalDate) -> BoardOccurrence {
    occurrence(of: quest, on: date, log: logs[date]?[quest.id])
  }

  private static let allDay = 1440

  private func occurrence(of quest: QuestRow, on date: LocalDate, log row: QuestLogRow?) -> BoardOccurrence {
    let ruleset = context.ruleset
    let schedule = quest.schedule
    let relation = context.relation(of: date)
    let log = row.map(OccurrenceLog.init)
    let status: OccurrenceStatus =
      if let log {
        .recorded(log.state)
      } else {
        switch relation {
        case .past: .unrecorded
        case .today: .open
        case .future: .upcoming
        }
      }
    let effectiveState: QuestLogState? =
      switch (status, relation) {
      case (.unrecorded, _), (.recorded(.rescheduled), .past): .missed
      case (.recorded(let state), _): state
      case (.open, _), (.upcoming, _): nil
      }
    let day = days[date]
    let mode = context.intensityMode(on: date, row: day)
    let streak = context.streak(quest)
    let locked = day.map { $0.lock == .active && $0.lockQuests.contains(quest.id) } ?? false
    let budget = RescheduleBudget.of(rescheduled[quest.id] ?? [], on: date)
    let transition = ruleset.applyStreakEvent(
      StreakEvent(state: .skipped, strictness: schedule.strictness, intensityMode: mode, streakOptIn: schedule.optionalStreakOptIn, onTime: false), to: quest.streak)
    let hp = ruleset.hpCost(
      of: HPBreak(occurrenceKey: "", strictness: schedule.strictness, state: .skipped, shielded: transition.shieldsConsumed > 0, streakDaysBefore: 0), in: mode)
    let streakBreak: StreakBreak =
      switch transition.outcome {
      case .bridge: .bridgedByShield(shieldsLeft: transition.state.shields)
      case .break: .ends(atDays: transition.endedAtDays)
      case .hold, .neutral: .untracked
      }
    let isScheduled = isScheduled(quest, on: date)
    let rules = OccurrenceRules(
      quest: quest, isScheduled: isScheduled, relation: relation, log: log, locked: locked, rescheduled: reschedules.contains(Occurrence(quest: quest.id, date: date)),
      budget: budget, ruleset: ruleset)
    return BoardOccurrence(
      occurrence: Occurrence(quest: quest.id, date: date), quest: context.snapshot(quest), streak: streak, isScheduled: isScheduled, status: status, log: log,
      effectiveState: effectiveState, locked: locked, intensityMode: mode,
      onTimeUntilMinute: ruleset.onTimeUntilMinute(strictness: schedule.strictness, startMinute: schedule.startTimeMinutes, durationMinutes: schedule.durationMinutes),
      breakCost: BreakCost(hp: hp, streak: streakBreak), reschedule: budget, actions: rules.actions)
  }
}

/// Which actions replay would take for one occurrence, in the order its handlers check (`ReplayState+Quests.swift`), and why the others are not offered.
/// A closed day keeps only the log's edits, as the reference's client does (`quest-presenters.ts:73`): replay would still take a late completion there, which
/// would let the owner collect late XP and streak days for any day of the past.
struct OccurrenceRules {
  let quest: QuestRow
  let isScheduled: Bool
  let relation: DayRelation
  let log: OccurrenceLog?
  let locked: Bool
  let rescheduled: Bool
  let budget: RescheduleBudget
  let ruleset: Ruleset

  var actions: OccurrenceActions {
    OccurrenceActions(
      complete: completion, partial: completion, skip: skip, postpone: postpone, reschedule: reschedule,
      attachReason: log.map { .availableUntil(millis: $0.editableUntilMillis) } ?? .unavailable(.nothingRecorded),
      deleteLog: log == nil ? .unavailable(.nothingRecorded) : .available)
  }

  private var strictness: Strictness { quest.schedule.strictness }

  private var occurring: ActionBlock? {
    if !quest.schedule.active { return .questInactive }
    return isScheduled ? nil : .notScheduled
  }

  /// A row the owner's action no longer replaces.
  private var held: ActionBlock? {
    guard let log, !log.isYielding else { return nil }
    return .alreadyRecorded(log.state)
  }

  private var completion: ActionAvailability {
    Self.availability(occurring ?? begun ?? held)
  }

  private var skip: ActionAvailability {
    Self.availability(occurring ?? begun ?? held)
  }

  private var postpone: ActionAvailability {
    let allowed: ActionBlock? = ruleset.strictness[strictness].allowsPostpone ? nil : .notAllowedFor(strictness)
    if let block = occurring ?? allowed ?? begun ?? held { return .unavailable(block) }
    return locked && relation == .today ? .needsConfirmation(.breaksPlanLock) : .available
  }

  private var reschedule: ActionAvailability {
    let allowed: ActionBlock? = ruleset.strictness[strictness].schedulingModel == .dayLevel ? .notAllowedFor(strictness) : nil
    let past: ActionBlock? = relation == .past ? .dayPassed : nil
    let moved: ActionBlock? = rescheduled ? .alreadyRescheduled : nil
    if let block = occurring ?? allowed ?? past ?? moved ?? held { return .unavailable(block) }
    guard budget.isCapReached else { return .available }
    let postponable = ruleset.strictness[strictness].allowsPostpone && relation == .today
    return postponable ? .needsConfirmation(.rescheduleBecomesPostpone(budget)) : .unavailable(.rescheduleCapReached(budget))
  }

  /// An outcome needs the day to have begun and not yet closed.
  private var begun: ActionBlock? {
    switch relation {
    case .past: .dayPassed
    case .today: nil
    case .future: .notYetBegun
    }
  }

  private static func availability(_ block: ActionBlock?) -> ActionAvailability {
    block.map(ActionAvailability.unavailable) ?? .available
  }
}
