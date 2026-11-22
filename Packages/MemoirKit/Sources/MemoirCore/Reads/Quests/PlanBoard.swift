import Foundation
import ShadowStore

public enum PlanScope: Sendable, Hashable {
  case week(containing: LocalDate)
  case month(containing: LocalDate)
}

public struct PlanBoardQuery: Sendable, Hashable {
  public let scope: PlanScope

  public init(scope: PlanScope) {
    self.scope = scope
  }
}

/// A day's planned minutes against the soft capacity: a note, never a limit (`fixture-provider.ts:63,523-535`).
public struct DayLoad: Sendable, Hashable {
  public static let softCapacityMinutes = 150

  public let minutes: Int
  public let occurrences: Int

  public var isOverCapacity: Bool { minutes > Self.softCapacityMinutes }
}

/// `lockNote` (`fixture-provider.ts:552-556`).
public enum PlanLockNote: String, Sendable, Hashable {
  case wasLocked
  case locked
}

public struct PlanDay: Sendable, Hashable, Identifiable {
  public let date: LocalDate
  public let relation: DayRelation
  public let lock: DayLockState
  public let lockNote: PlanLockNote?
  public let load: DayLoad
  public let occurrences: [BoardOccurrence]

  public var id: LocalDate { date }
}

/// A cell of the month grid: whole weeks from the week holding the 1st, a trailing week wholly outside the month dropped (`fixture-provider.ts:558-573`).
public struct PlanMonthCell: Sendable, Hashable, Identifiable {
  public let date: LocalDate
  public let isInMonth: Bool
  public let relation: DayRelation
  public let lock: DayLockState
  /// Each scheduled occurrence's board state; empty outside the month.
  public let outcomes: [QuestLogState?]

  public var id: LocalDate { date }
}

/// `carryOver` (`fixture-provider.ts:446-466`): yesterday's genuine misses, the quest missed most in the week before named first, then the longest run.
public struct CarryOver: Sendable, Hashable {
  public let missed: Int
  public let quest: UUID
  public let name: String?
  public let longestDays: Int
  /// Whether its streak ended with the miss (`fixture-provider.ts:478-483`): it keeps one, had one, has none now and no shield covered yesterday.
  public let streakEnded: Bool
}

/// The quest with the most reschedules counted for the open day (`fixture-provider.ts:484-490`); nil when none has used any.
public struct BusiestReschedule: Sendable, Hashable {
  public let quest: UUID
  public let name: String?
  public let budget: RescheduleBudget
}

/// `glance` (`fixture-provider.ts:493-505`); only completed occurrences count as kept here.
public struct PlanGlance: Sendable, Hashable {
  public let scheduled: Int
  public let completed: Int
  public let heaviestDay: LocalDate?
  public let hp: Int?
  public let hpMax: Int?
  public let shields: ShieldStanding
}

/// The Plan screen for a week or a month: each day's occurrences and load, the locks, the Crown and the reschedule budget.
public struct PlanBoard: ReplayReadModel {
  public static let recentMissWindowDays = 7

  public let scope: PlanScope
  public let from: LocalDate
  public let through: LocalDate
  public let weekStart: LocalDate.Weekday
  public let openDay: LocalDate?
  /// The week's days; for a month, the days of the week holding the anchor.
  public let days: [PlanDay]
  /// Nil for a week.
  public let month: [PlanMonthCell]?
  /// Only for the week holding the open day.
  public let carryOver: CarryOver?
  public let crown: CrownWindow?
  public let busiestReschedule: BusiestReschedule?
  public let glance: PlanGlance
  /// The advisory a lock of the open day is measured against.
  public let lockCapacity: LockCapacity?
  public let changesOn: LocalDate?

  public static func load(_ query: PlanBoardQuery, in transaction: ReadTransaction) throws(StoreError) -> PlanBoard {
    let context = try QuestReadContext.load(in: transaction)
    let weekStart = context.weekStart
    let anchor: LocalDate
    let isMonth: Bool
    switch query.scope {
    case .week(let date): (anchor, isMonth) = (date, false)
    case .month(let date): (anchor, isMonth) = (date, true)
    }
    let week = startOfWeek(anchor, weekStart: weekStart)
    let monthCells = isMonth ? monthGrid(anchor, weekStart: weekStart) : nil
    let isCurrentWeek = !isMonth && (context.openDay.map { $0 >= week && $0 <= week.movedBy(days: 6) } ?? false)
    let first = min(week, monthCells?.first?.date ?? week)
    let from = isCurrentWeek ? min(first, context.openDay?.movedBy(days: -recentMissWindowDays) ?? first) : first
    let through = max(week.movedBy(days: 6), monthCells?.last?.date ?? week)
    let source = try OccurrenceSource.load(context, from: from, through: through, in: transaction)

    let days = (0..<7).map { week.movedBy(days: $0) }.map { planDay($0, source: source) }
    let month = monthCells.map { cells in
      cells.map { cell in
        let row = source.days[cell.date]
        return PlanMonthCell(
          date: cell.date, isInMonth: cell.inMonth, relation: context.relation(of: cell.date), lock: row?.lock ?? .none,
          outcomes: cell.inMonth ? source.occurrences(on: cell.date).filter(\.isScheduled).map(\.effectiveState) : [])
      }
    }
    let periodDays = isMonth ? (monthCells ?? []).filter(\.inMonth).map { planDay($0.date, source: source) } : days
    let ruleset = context.ruleset
    let openRow = context.openDayRow
    return PlanBoard(
      scope: query.scope, from: isMonth ? (monthCells?.first { $0.inMonth }?.date ?? week) : week,
      through: isMonth ? (monthCells?.last { $0.inMonth }?.date ?? week) : week.movedBy(days: 6), weekStart: weekStart, openDay: context.openDay, days: days,
      month: month, carryOver: isCurrentWeek ? carryOver(source) : nil,
      crown: try context.openDay.flatMap { day throws(StoreError) in try CrownWindow.load(containing: day, row: openRow, ruleset: ruleset, in: transaction) },
      busiestReschedule: try busiest(context, in: transaction),
      glance: PlanGlance(
        scheduled: periodDays.map { $0.occurrences.count(where: \.isScheduled) }.reduce(0, +),
        completed: periodDays.map { $0.occurrences.count { $0.isScheduled && $0.effectiveState == .completed } }.reduce(0, +),
        heaviestDay: periodDays.filter { $0.load.minutes > 0 }.max { $0.load.minutes < $1.load.minutes }?.date, hp: openRow?.hp?.hpEnd,
        hpMax: openRow?.hp?.hpMax, shields: ShieldStanding(context.quests, ruleset: ruleset)),
      lockCapacity: try context.openDay.flatMap { day throws(StoreError) in
        try TodayBoard.capacity(
          on: day, plannedLoad: context.activeQuests.count { source.isScheduled($0, on: day) }, momentum: openRow?.momentum ?? .steady, context: context,
          ruleset: ruleset, in: transaction)
      },
      changesOn: context.changesOn)
  }

  static func startOfWeek(_ date: LocalDate, weekStart: LocalDate.Weekday) -> LocalDate {
    date.movedBy(days: -((date.weekday.rawValue - weekStart.rawValue + 7) % 7))
  }

  static func monthGrid(_ anchor: LocalDate, weekStart: LocalDate.Weekday) -> [(date: LocalDate, inMonth: Bool)] {
    guard
      let first = LocalDate(year: anchor.year, month: anchor.month, day: 1),
      let last = LocalDate(year: anchor.year, month: anchor.month, day: LocalDate.daysInMonth(year: anchor.year, month: anchor.month))
    else { return [] }
    let start = startOfWeek(first, weekStart: weekStart)
    let end = startOfWeek(last, weekStart: weekStart).movedBy(days: 6)
    return (0...end.days(since: start)).map { start.movedBy(days: $0) }.map { ($0, $0.month == anchor.month && $0.year == anchor.year) }
  }

  private static func planDay(_ date: LocalDate, source: OccurrenceSource) -> PlanDay {
    let context = source.context
    let occurrences = source.occurrences(on: date)
    let scheduled = occurrences.filter(\.isScheduled)
    let row = source.days[date]
    let lock = row?.lock ?? .none
    let note: PlanLockNote? =
      switch (lock, context.relation(of: date)) {
      case (.active, .past): .wasLocked
      case (.active, _): .locked
      default: nil
      }
    return PlanDay(
      date: date, relation: context.relation(of: date), lock: lock, lockNote: note,
      load: DayLoad(minutes: Exact.sum(scheduled.map { max(0, $0.quest.durationMinutes) }), occurrences: scheduled.count), occurrences: occurrences)
  }

  private static func carryOver(_ source: OccurrenceSource) -> CarryOver? {
    let context = source.context
    guard let yesterday = context.openDay?.movedBy(days: -1) else { return nil }
    let missed = source.occurrences(on: yesterday).filter { $0.isScheduled && $0.effectiveState == .missed }
    let recentMisses = Dictionary(
      missed.map { occurrence in
        (
          occurrence.quest.id,
          (0..<recentMissWindowDays).count { back in
            let day = yesterday.movedBy(days: -back)
            guard let quest = context.questsByID[occurrence.quest.id], source.isScheduled(quest, on: day) else { return false }
            return source.occurrence(of: quest, on: day).effectiveState == .missed
          }
        )
      }
    ) { first, _ in first }
    guard
      let worst = missed.enumerated().sorted(by: { lhs, rhs in
        let left = recentMisses[lhs.element.quest.id] ?? 0
        let right = recentMisses[rhs.element.quest.id] ?? 0
        if left != right { return left > right }
        if lhs.element.streak.longestDays != rhs.element.streak.longestDays { return lhs.element.streak.longestDays > rhs.element.streak.longestDays }
        return lhs.offset < rhs.offset
      }).first?.element
    else { return nil }
    let streak = worst.streak
    let ended = streak.isTracked && streak.longestDays > 0 && streak.currentDays == 0 && worst.log?.shielded != true
    return CarryOver(missed: missed.count, quest: worst.quest.id, name: worst.quest.name, longestDays: streak.longestDays, streakEnded: ended)
  }

  private static func busiest(_ context: QuestReadContext, in transaction: ReadTransaction) throws(StoreError) -> BusiestReschedule? {
    guard let day = context.openDay else { return nil }
    let rows = try MemoirDerived.reschedules(from: day.movedBy(days: -(RescheduleBudget.windowDays - 1)), through: .latest, in: transaction)
    let rescheduled = Dictionary(grouping: rows, by: \.occurrence.quest).mapValues { $0.map(\.occurrence.date) }
    var best: BusiestReschedule?
    for quest in context.activeQuests {
      let budget = RescheduleBudget.of(rescheduled[quest.id] ?? [], on: day)
      if budget.used > (best?.budget.used ?? 0) { best = BusiestReschedule(quest: quest.id, name: context.records[quest.id]?.name, budget: budget) }
    }
    return best
  }
}
