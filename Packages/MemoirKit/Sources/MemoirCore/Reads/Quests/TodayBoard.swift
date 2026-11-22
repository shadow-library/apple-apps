import Foundation
import ShadowStore

public struct TodayBoardQuery: Sendable, Hashable {
  public let date: LocalDate

  public init(date: LocalDate) {
    self.date = date
  }
}

/// A day's state as replay left it: HP, Crown, momentum, Comeback and Returner. Nil on the board for a day the walk has not opened.
public struct DaySummary: Sendable, Hashable {
  public let date: LocalDate
  public let isClosed: Bool
  public let intensityMode: IntensityMode
  public let hp: DayHP?
  public let crown: CrownWindow?
  public let momentum: MomentumBucket
  public let comeback: ComebackStanding
  public let returnerFired: Bool
  public let missedCount: Int
}

/// The day's plan lock and whether it can be set or cleared: only on the account's open day, and only over active quests scheduled on it
/// (`compassion-commands.service.ts`, `fixture-provider.ts:802-813`). `capacity` is the advisory the lock is measured against and never refuses it.
public struct DayLockSummary: Sendable, Hashable {
  public let state: DayLockState
  public let quests: [UUID]
  public let lock: ActionAvailability
  public let unlock: ActionAvailability
  public let capacity: LockCapacity?
}

/// A day's Recovery quest and whether it can be completed: only while pending and only on its own day, the account's open day.
public struct RecoveryOffer: Sendable, Hashable {
  public let id: UUID
  public let date: LocalDate
  public let sourceQuest: UUID?
  public let sourceName: String?
  public let state: RecoveryQuestState
  public let isReturnerDay: Bool
  public let expiresAtMillis: Int64?
  public let complete: ActionAvailability
}

/// The soonest occurrence after a day with nothing scheduled (`fixture-provider.ts:331-337`).
public struct NextOccurrence: Sendable, Hashable {
  public let quest: UUID
  public let name: String?
  public let date: LocalDate
}

/// Everything the Today screen shows for one day; read from the projection, never by running replay.
public struct TodayBoard: ReplayReadModel {
  public let date: LocalDate
  /// The view's open day; nil before the first command.
  public let openDay: LocalDate?
  public let relation: DayRelation
  public let occurrences: [BoardOccurrence]
  public let tally: DayTally
  public let recovery: RecoveryOffer?
  public let summary: DaySummary?
  public let lock: DayLockSummary
  public let nextScheduled: NextOccurrence?
  /// Set only on the open day.
  public let comingBack: ComingBackReason?
  public let scheduleWindow: ScheduleWindow
  public let notices: [ReplayNotice]
  /// Set when replay stopped at a command this build cannot read.
  public let halt: ReplayHalt?
  public let changesOn: LocalDate?

  public static func load(_ query: TodayBoardQuery, in transaction: ReadTransaction) throws(StoreError) -> TodayBoard {
    let context = try QuestReadContext.load(in: transaction)
    let date = query.date
    let source = try OccurrenceSource.load(context, from: date, through: date, in: transaction)
    let occurrences = source.occurrences(on: date)
    let row = source.days[date]
    let ruleset = row.flatMap { Ruleset.version($0.rulesetVersion) } ?? context.ruleset
    let recoveryRow = try MemoirDerived.recoveries(from: date, through: date, in: transaction).first
    let relation = context.relation(of: date)
    return TodayBoard(
      date: date, openDay: context.openDay, relation: relation, occurrences: occurrences, tally: DayTally(occurrences),
      recovery: recoveryRow.map { offer($0.recovery, relation: relation, context: context) },
      summary: try row.map { row throws(StoreError) in try summary(row, ruleset: ruleset, in: transaction) },
      lock: try lock(on: date, row: row, source: source, ruleset: ruleset, in: transaction),
      nextScheduled: occurrences.isEmpty ? next(after: date, context: context) : nil,
      comingBack: relation == .today ? ComingBackReason.on(row, recovery: recoveryRow) : nil, scheduleWindow: context.scheduleWindow,
      notices: try MemoirDerived.notices(in: transaction).map(\.notice), halt: context.hero?.halt, changesOn: context.changesOn)
  }

  private static func summary(_ row: DayRow, ruleset: Ruleset, in transaction: ReadTransaction) throws(StoreError) -> DaySummary {
    DaySummary(
      date: row.date, isClosed: row.isClosed, intensityMode: row.intensityMode, hp: row.hp,
      crown: try CrownWindow.load(containing: row.date, row: row, ruleset: ruleset, in: transaction), momentum: row.momentum,
      comeback: ComebackStanding(row, ruleset: ruleset), returnerFired: row.returnerFired, missedCount: row.missedCount)
  }

  static func offer(_ recovery: RecoveryQuest, relation: DayRelation, context: QuestReadContext) -> RecoveryOffer {
    let complete: ActionAvailability =
      if relation != .today {
        .unavailable(.notAccountDay)
      } else if recovery.state != .pending {
        .unavailable(.recoveryClosed(recovery.state))
      } else {
        .available
      }
    return RecoveryOffer(
      id: recovery.id, date: recovery.date, sourceQuest: recovery.sourceQuest, sourceName: recovery.sourceQuest.flatMap { context.records[$0]?.name },
      state: recovery.state, isReturnerDay: recovery.isReturnerDay, expiresAtMillis: recovery.expiresAtMillis, complete: complete)
  }

  private static func lock(
    on date: LocalDate, row: DayRow?, source: OccurrenceSource, ruleset: Ruleset, in transaction: ReadTransaction
  ) throws(StoreError) -> DayLockSummary {
    let context = source.context
    let state = row?.lock ?? .none
    let lockable = context.activeQuests.filter { source.isScheduled($0, on: date) }
    guard context.relation(of: date) == .today, row?.isClosed != true else {
      return DayLockSummary(
        state: state, quests: row?.lockQuests ?? [], lock: .unavailable(.notAccountDay), unlock: .unavailable(.notAccountDay), capacity: nil)
    }
    return DayLockSummary(
      state: state, quests: row?.lockQuests ?? [], lock: lockable.isEmpty ? .unavailable(.nothingToLock) : .available,
      unlock: state == .none ? .unavailable(.notLocked) : .available,
      capacity: try capacity(on: date, plannedLoad: lockable.count, momentum: row?.momentum ?? .steady, context: context, ruleset: ruleset, in: transaction))
  }

  /// `ReplayState.lockCapacity` over the derived rows: daily hold counts before the day, since the account began.
  static func capacity(
    on date: LocalDate, plannedLoad: Int, momentum: MomentumBucket, context: QuestReadContext, ruleset: Ruleset, in transaction: ReadTransaction
  ) throws(StoreError) -> LockCapacity {
    let began = [try MemoirDerived.earliestQuestLogDate(in: transaction), context.hero?.firstQuestDay].compactMap(\.self).min()
    var trailing = [Int]()
    if let began {
      let window = ruleset.capacity.medianWindowDays
      let logs = try MemoirDerived.questLogs(from: date.movedBy(days: -max(1, window)), through: date.movedBy(days: -1), in: transaction)
      trailing = (1...max(1, window)).map { date.movedBy(days: -$0) }.filter { $0 >= began }.map { day in
        logs.count { $0.occurrence.date == day && $0.entry.isHold }
      }
    }
    let capacity = ruleset.capacity(for: CapacityInput(trailingCompletions: trailing, momentum: momentum, priorDayHeavyMiss: false))
    let warning = ruleset.capacityWarning(
      for: CapacityWarningInput(plannedLoad: plannedLoad, capacity: capacity.capacity, onLockAttempt: true, daysSinceLastSoftWarning: nil))
    return LockCapacity(capacity: capacity, warning: warning)
  }

  private static func next(after date: LocalDate, context: QuestReadContext) -> NextOccurrence? {
    let tomorrow = date.movedBy(days: 1)
    return context.activeQuests.compactMap { quest -> NextOccurrence? in
      guard let next = quest.schedule.recurrence.nextOccurrence(onOrAfter: tomorrow) else { return nil }
      return NextOccurrence(quest: quest.id, name: context.records[quest.id]?.name, date: next.date)
    }.min { $0.date < $1.date }
  }
}
