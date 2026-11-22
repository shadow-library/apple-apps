import Foundation
import ShadowStore

public enum QuestFilter: String, Sendable, Hashable, CaseIterable {
  case active
  case inactive
  case all
}

public struct QuestListQuery: Sendable, Hashable {
  public let filter: QuestFilter
  /// Matched against the quest's name ignoring case, diacritics and width; empty lists every quest the filter keeps.
  public let search: String

  public init(filter: QuestFilter = .active, search: String = "") {
    self.filter = filter
    self.search = search
  }
}

/// `adherenceOf` over the 30 days ending on the open day (`lib/data/reflect.derive.ts:131-170`, `lib/sync/projection.ts:225-245`): a partial holds
/// half an occurrence, and a postponed or rescheduled one is counted where it moved to, not where it was planned. Fewer than three counted
/// occurrences give no ratio.
public struct QuestListAdherence: Sendable, Hashable {
  public static let windowDays = 30
  public static let minimumOccurrences = 3

  public let held: Halves
  public let occurrences: Int

  /// Nil below the minimum.
  public var ratio: Fraction? {
    guard occurrences >= Self.minimumOccurrences else { return nil }
    return Fraction(numerator: held.halves, denominator: occurrences * 2)
  }

  init(_ logs: [QuestLogRow]) {
    let counted = logs.filter { $0.entry.state != .postponed && $0.entry.state != .rescheduled }
    held = Halves(Exact.sum(counted.map { Self.holdHalves($0.entry.state) }))
    occurrences = counted.count
  }

  private static func holdHalves(_ state: QuestLogState) -> Int {
    switch state {
    case .completed, .late, .recovery: 2
    case .partial: 1
    case .skipped, .missed, .postponed, .rescheduled: 0
    }
  }
}

public struct QuestSummary: Sendable, Hashable, Identifiable {
  public let quest: QuestSnapshot
  public let streak: StreakSummary
  /// The cap of a reschedule of the open day's occurrence.
  public let reschedule: RescheduleBudget
  /// In the open day's active lock, so its schedule stays as planned until the day closes.
  public let lockedToday: Bool
  public let adherence: QuestListAdherence
  public let xpEarned: Int

  public var id: UUID { quest.id }
}

/// The quests replay knows, in the order they were created; a quest whose create command has not arrived is not listed yet, even if its words have.
public struct QuestList: ReplayReadModel {
  public let filter: QuestFilter
  public let search: String
  public let entries: [QuestSummary]
  public let openDay: LocalDate?
  public let halt: ReplayHalt?
  public let changesOn: LocalDate?

  public static func load(_ query: QuestListQuery, in transaction: ReadTransaction) throws(StoreError) -> QuestList {
    let context = try QuestReadContext.load(in: transaction)
    let needle = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
    let kept = context.quests.filter { quest in
      switch query.filter {
      case .active: quest.schedule.active
      case .inactive: !quest.schedule.active
      case .all: true
      }
    }.filter { quest in
      guard !needle.isEmpty else { return true }
      return context.records[quest.id]?.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }
    let summaries = try QuestSummaries.load(context, in: transaction)
    return QuestList(
      filter: query.filter, search: query.search, entries: kept.map(summaries.summary), openDay: context.openDay, halt: context.hero?.halt,
      changesOn: context.changesOn)
  }
}

/// The per-quest figures a list and a quest's page share, read once for every quest.
struct QuestSummaries {
  let context: QuestReadContext
  let tallies: [QuestLogTally]
  let windowLogs: [UUID: [QuestLogRow]]
  let rescheduled: [UUID: [LocalDate]]
  let day: LocalDate

  static func load(_ context: QuestReadContext, in transaction: ReadTransaction) throws(StoreError) -> QuestSummaries {
    let day = context.openDay ?? .earliest
    let logs = try MemoirDerived.questLogs(from: day.movedBy(days: -(QuestListAdherence.windowDays - 1)), through: day, in: transaction)
    var rescheduled = [UUID: [LocalDate]]()
    for row in try MemoirDerived.reschedules(from: day.movedBy(days: -(RescheduleBudget.windowDays - 1)), through: .latest, in: transaction) {
      rescheduled[row.occurrence.quest, default: []].append(row.occurrence.date)
    }
    return QuestSummaries(
      context: context, tallies: try MemoirDerived.questLogTallies(in: transaction), windowLogs: Dictionary(grouping: logs, by: \.occurrence.quest),
      rescheduled: rescheduled, day: day)
  }

  func summary(_ quest: QuestRow) -> QuestSummary {
    QuestSummary(
      quest: context.snapshot(quest), streak: context.streak(quest), reschedule: RescheduleBudget.of(rescheduled[quest.id] ?? [], on: day),
      lockedToday: context.isLockedToday(quest.id), adherence: QuestListAdherence(windowLogs[quest.id] ?? []),
      xpEarned: Exact.sum(tallies.filter { $0.quest == quest.id }.map(\.xp)))
  }
}

public struct QuestDetailQuery: Sendable, Hashable {
  public let quest: UUID
  public let historyLimit: Int

  public init(quest: UUID, historyLimit: Int = 30) {
    self.quest = quest
    self.historyLimit = historyLimit
  }
}

/// A quest's lifetime counts by state, and what its logs earned.
public struct QuestTotals: Sendable, Hashable {
  public let byState: [QuestLogState: Int]
  public let xp: Int
  public let coins: Int

  init(_ tallies: [QuestLogTally]) {
    byState = Dictionary(tallies.map { ($0.state, $0.count) }) { $0 + $1 }
    xp = Exact.sum(tallies.map(\.xp))
    coins = Exact.sum(tallies.map(\.coins))
  }
}

/// The quest's share of the week (`fixture-provider.ts:603-633`): days a week it runs (every `n` days runs ⌈7 / n⌉ times, a weekly quest on its days
/// whatever its interval, a monthly one 12/52 and, where the reference has none, a yearly one 1/52) times its usual length, against every active quest's.
public struct QuestLoad: Sendable, Hashable {
  public let daysPerWeek: Fraction
  public let weeklyMinutes: Fraction
  /// Nil when no active quest takes any time.
  public let share: Fraction?

  init(_ quest: QuestRow, among active: [QuestRow]) {
    daysPerWeek = Self.daysPerWeek(quest.schedule.recurrence)
    weeklyMinutes = daysPerWeek * Fraction(max(0, quest.schedule.durationMinutes))
    let total = active.map { Self.daysPerWeek($0.schedule.recurrence) * Fraction(max(0, $0.schedule.durationMinutes)) }.reduce(Fraction.zero, Self.sum)
    share = weeklyMinutes / total
  }

  private static func sum(_ lhs: Fraction, _ rhs: Fraction) -> Fraction {
    Fraction(
      reducing: Int128(lhs.numerator) * Int128(rhs.denominator) + Int128(rhs.numerator) * Int128(lhs.denominator), Int128(lhs.denominator) * Int128(rhs.denominator))
  }

  static func daysPerWeek(_ rule: RecurrenceRule) -> Fraction {
    switch rule.frequency {
    case .daily: Fraction((LocalDate.daysPerWeek + max(1, rule.interval) - 1) / max(1, rule.interval))
    case .weekly(let weekdays): Fraction(weekdays.count)
    case .monthly: Fraction(numerator: 12, denominator: 52) ?? .zero
    case .yearly: Fraction(numerator: 1, denominator: 52) ?? .zero
    }
  }
}

/// One quest's page: its summary, today's occurrence when it runs today, its latest logs, lifetime totals and load, and whether its schedule may change.
public struct QuestDetail: ReplayReadModel {
  /// Nil when replay knows no such quest.
  public let summary: QuestSummary?
  public let today: BoardOccurrence?
  /// Latest first, on or before the open day.
  public let history: [OccurrenceLogEntry]
  public let totals: QuestTotals
  public let load: QuestLoad?
  public let scheduleEdit: ActionAvailability
  public let halt: ReplayHalt?
  public let changesOn: LocalDate?

  public static func load(_ query: QuestDetailQuery, in transaction: ReadTransaction) throws(StoreError) -> QuestDetail {
    let context = try QuestReadContext.load(in: transaction)
    guard let quest = context.questsByID[query.quest] else {
      return QuestDetail(
        summary: nil, today: nil, history: [], totals: QuestTotals([]), load: nil, scheduleEdit: .unavailable(.questInactive), halt: context.hero?.halt,
        changesOn: context.changesOn)
    }
    let summaries = try QuestSummaries.load(context, in: transaction)
    let today = try context.openDay.flatMap { day throws(StoreError) -> BoardOccurrence? in
      let source = try OccurrenceSource.load(context, from: day, through: day, in: transaction)
      return source.isScheduled(quest, on: day) || source.logs[day]?[quest.id] != nil ? source.occurrence(of: quest, on: day) : nil
    }
    let history = try MemoirDerived.questLogs(of: quest.id, through: context.openDay ?? .latest, limit: query.historyLimit, in: transaction)
    let scheduleEdit: ActionAvailability =
      if !quest.schedule.active {
        .unavailable(.questInactive)
      } else if context.isLockedToday(quest.id) {
        .unavailable(.lockedInTodaysPlan)
      } else {
        .available
      }
    return QuestDetail(
      summary: summaries.summary(quest), today: today, history: history.map(OccurrenceLogEntry.init), totals: QuestTotals(summaries.tallies.filter { $0.quest == quest.id }),
      load: QuestLoad(quest, among: context.activeQuests), scheduleEdit: scheduleEdit, halt: context.hero?.halt, changesOn: context.changesOn)
  }
}

public struct OccurrenceLogEntry: Sendable, Hashable, Identifiable {
  public let date: LocalDate
  public let log: OccurrenceLog

  public var id: LocalDate { date }

  init(_ row: QuestLogRow) {
    date = row.occurrence.date
    log = OccurrenceLog(row)
  }
}
