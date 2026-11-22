import Foundation
import ShadowStore

public struct StreakBoardQuery: Sendable, Hashable {
  public static let defaultLimit = 3

  public let date: LocalDate
  public let limit: Int

  public init(date: LocalDate, limit: Int = defaultLimit) {
    self.date = date
    self.limit = limit
  }
}

/// One of the seven days a streak row shows: nil `state` on a scheduled day still open or upcoming.
public struct StreakBoardDay: Sendable, Hashable {
  public let date: LocalDate
  public let isScheduled: Bool
  public let state: QuestLogState?
  public let shielded: Bool
}

public struct StreakBoardEntry: Sendable, Hashable, Identifiable {
  public let quest: UUID
  public let name: String?
  public let streak: StreakSummary
  /// For a run that has ended and had reached a week (`fixture-provider.ts:353`): the day it closed, the first unshielded break after the last kept day,
  /// else the first scheduled day after it (`fixture-provider.ts:367-376`); nil when neither is known.
  public let endedOn: LocalDate?
  public let showsEnd: Bool
  /// The seven days ending on the board's date, oldest first.
  public let week: [StreakBoardDay]

  public var id: UUID { quest }
}

/// The active quests with the longest current runs (`fixture-provider.ts:340-358`), each with its last seven days.
public struct StreakBoard: ReplayReadModel {
  public static let weekDays = 7
  public static let endNoteMinimumDays = 7

  public let date: LocalDate
  public let entries: [StreakBoardEntry]
  public let changesOn: LocalDate?

  public static func load(_ query: StreakBoardQuery, in transaction: ReadTransaction) throws(StoreError) -> StreakBoard {
    let context = try QuestReadContext.load(in: transaction)
    let first = query.date.movedBy(days: -(weekDays - 1))
    let source = try OccurrenceSource.load(context, from: first, through: query.date, in: transaction)
    let ranked = context.activeQuests.enumerated().sorted { lhs, rhs in
      lhs.element.streak.currentDays != rhs.element.streak.currentDays ? lhs.element.streak.currentDays > rhs.element.streak.currentDays : lhs.offset < rhs.offset
    }.map(\.element).prefix(max(0, query.limit))
    var entries = [StreakBoardEntry]()
    for quest in ranked {
      let week = (0..<weekDays).map { first.movedBy(days: $0) }.map { day -> StreakBoardDay in
        guard source.isScheduled(quest, on: day) else { return StreakBoardDay(date: day, isScheduled: false, state: nil, shielded: false) }
        let occurrence = source.occurrence(of: quest, on: day)
        return StreakBoardDay(date: day, isScheduled: true, state: occurrence.effectiveState, shielded: occurrence.log?.shielded ?? false)
      }
      let showsEnd = quest.streak.currentDays == 0 && quest.streak.longestDays >= endNoteMinimumDays
      entries.append(
        StreakBoardEntry(
          quest: quest.id, name: context.records[quest.id]?.name, streak: context.streak(quest),
          endedOn: showsEnd ? try endDate(of: quest, through: query.date, in: transaction) : nil, showsEnd: showsEnd, week: week))
    }
    return StreakBoard(date: query.date, entries: entries, changesOn: context.changesOn)
  }

  /// The day walk writes a miss for every day away, so the run closed at the first unshielded break after the last kept day, not the latest one.
  static func endDate(of quest: QuestRow, through date: LocalDate, in transaction: ReadTransaction) throws(StoreError) -> LocalDate? {
    let logs = try MemoirDerived.questLogs(of: quest.id, through: date, limit: nil, in: transaction).reversed()
    let lastHold = logs.last { $0.entry.isHold }?.occurrence.date
    if let breakLog = logs.first(where: { row in (lastHold.map { row.occurrence.date > $0 } ?? true) && row.entry.isBreak && !row.shielded }) {
      return breakLog.occurrence.date
    }
    guard let lastHold else { return nil }
    return quest.schedule.recurrence.nextOccurrence(onOrAfter: lastHold.movedBy(days: 1)).map(\.date).flatMap { $0 <= date ? $0 : nil }
  }
}
