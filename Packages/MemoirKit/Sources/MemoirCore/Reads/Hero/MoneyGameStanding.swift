import Foundation
import ShadowStore

public struct MoneyGameQuery: Sendable, Hashable {
  public init() {}
}

/// One week's money logging, anchored on the money rules' weekday: the days covered so far against the days it needs to extend the money streak.
public struct MoneyWeekProgress: Sendable, Hashable {
  public let start: LocalDate
  public let end: LocalDate
  public let covered: [LocalDate]
  public let required: Int
  /// Uncovered days of the week the owner can still cover: those in the late window, the account's day and the days after it.
  public let coverable: Int

  public var isAccounted: Bool { covered.count >= required }
  public var canStillBeAccounted: Bool { covered.count + coverable >= required }
}

/// A day of the logging window: what covered it, if anything, and whether "No spend" may be logged for it.
public struct MoneyLogDay: Sendable, Hashable, Identifiable {
  public let date: LocalDate
  public let coverage: MoneyLogSource?
  public let noSpend: ActionAvailability

  public var id: LocalDate { date }
}

/// A period close replay kept, with what it did to the hero; a later close of the same period was superseded and never shows.
public struct MoneyCloseSummary: Sendable, Hashable, Identifiable {
  public let key: MoneyCloseKey
  /// Nil while the budget's record is missing, unreadable or unnamed.
  public let budgetName: String?
  public let closedOn: LocalDate
  public let outcome: BudgetCloseOutcome
  public let deposited: Bool
  public let result: MoneyCloseResult

  public var id: MoneyCloseKey { key }
}

/// Money in the game as of the account's open day: the money and saving streaks, this week's logging (and last week's while it can still change), the debuff
/// in force, the latest closes, and the days of the logging window with whether replay would take "No spend" for each. A replay halt leaves it as replay
/// last stood and withholds nothing: a command logged meanwhile is taken, under its own account day, once the app can read on.
public struct MoneyGameStanding: ReplayReadModel {
  public static let recentCloseLimit = 5

  public let openDay: LocalDate?
  public let weekStreak: Int
  public let savingStreak: Int
  /// Nil until the first command taken under money rules.
  public let lastActivityDay: LocalDate?
  public let debuff: MoneyRow.Debuff?
  /// The week holding the open day; nil before the walk opens a day.
  public let week: MoneyWeekProgress?
  /// The week before, while its days can still be covered and it has not settled.
  public let settlingWeek: MoneyWeekProgress?
  /// The open day, then the earlier days of the late window; empty before the walk opens a day.
  public let logging: [MoneyLogDay]
  /// Newest first.
  public let recentCloses: [MoneyCloseSummary]
  public let changesOn: LocalDate?

  public var today: MoneyLogDay? { logging.first }

  /// The earlier days of the window nothing has covered yet.
  public var backFill: [MoneyLogDay] { logging.dropFirst().filter { $0.coverage == nil } }

  public static func load(_ query: MoneyGameQuery, in transaction: ReadTransaction) throws(StoreError) -> MoneyGameStanding {
    try load(openDay: try MemoirDerived.hero(in: transaction)?.openDay, in: transaction)
  }

  static func load(openDay: LocalDate?, in transaction: ReadTransaction) throws(StoreError) -> MoneyGameStanding {
    let row = try MemoirDerived.money(in: transaction)
    let rules = Ruleset.current.money
    var week: MoneyWeekProgress?
    var settlingWeek: MoneyWeekProgress?
    var logging = [MoneyLogDay]()
    if let openDay, let rules {
      let start = PlanBoard.startOfWeek(openDay, weekStart: rules.weekAnchorWeekday)
      let previous = start.movedBy(days: -LocalDate.daysPerWeek)
      let covered = Dictionary(
        try MemoirDerived.coveredDays(from: min(previous, openDay.movedBy(days: -rules.lateDays)), through: openDay, in: transaction).map { ($0.date, $0.source) }
      ) { first, _ in first }
      week = progress(from: start, openDay: openDay, covered: covered, rules: rules)
      if openDay.days(since: start.movedBy(days: -1)) <= rules.lateDays { settlingWeek = progress(from: previous, openDay: openDay, covered: covered, rules: rules) }
      logging = (0...rules.lateDays).map { offset in
        let date = openDay.movedBy(days: -offset)
        return MoneyLogDay(date: date, coverage: covered[date], noSpend: noSpend(on: date, openDay: openDay, coverage: covered[date], rules: rules))
      }
    }
    return MoneyGameStanding(
      openDay: openDay, weekStreak: row?.weekStreak ?? 0, savingStreak: row?.savingStreak ?? 0, lastActivityDay: row?.lastActivityDay, debuff: row?.debuff,
      week: week, settlingWeek: settlingWeek, logging: logging, recentCloses: try recentCloses(in: transaction), changesOn: openDay?.adding(days: 1))
  }

  /// As `ReplayState.logNoSpend` judges a command issued on the open day: only a day in the late window, and only while nothing covers it.
  public func noSpend(on date: LocalDate) -> ActionAvailability {
    guard let openDay, let rules = Ruleset.current.money else { return .unavailable(.loggingWindowClosed) }
    return Self.noSpend(on: date, openDay: openDay, coverage: logging.first { $0.date == date }?.coverage, rules: rules)
  }

  private static func noSpend(on date: LocalDate, openDay: LocalDate, coverage: MoneyLogSource?, rules: MoneyRules) -> ActionAvailability {
    if date > openDay { return .unavailable(.notYetBegun) }
    if openDay.days(since: date) > rules.lateDays { return .unavailable(.loggingWindowClosed) }
    return coverage.map { .unavailable(.alreadyCovered($0)) } ?? .available
  }

  private static func progress(from start: LocalDate, openDay: LocalDate, covered: [LocalDate: MoneyLogSource], rules: MoneyRules) -> MoneyWeekProgress {
    let days = (0..<LocalDate.daysPerWeek).map { start.movedBy(days: $0) }
    let firstCoverable = openDay.movedBy(days: -rules.lateDays)
    return MoneyWeekProgress(
      start: start, end: start.movedBy(days: LocalDate.daysPerWeek - 1), covered: days.filter { covered[$0] != nil }, required: rules.weekMinCovered,
      coverable: days.count { $0 >= firstCoverable && covered[$0] == nil })
  }

  private static func recentCloses(in transaction: ReadTransaction) throws(StoreError) -> [MoneyCloseSummary] {
    let rows = try MemoirDerived.moneyCloses(in: transaction).sorted { first, second in
      if first.close.closedOn != second.close.closedOn { return first.close.closedOn > second.close.closedOn }
      if first.key.periodStart != second.key.periodStart { return first.key.periodStart > second.key.periodStart }
      return first.key.budget.uuidString < second.key.budget.uuidString
    }
    return try rows.prefix(recentCloseLimit).map { row throws(StoreError) in
      let name: String? =
        switch try BudgetRecord.read(id: row.key.budget, in: transaction) {
        case .readable(let entry): entry.record.name
        case .absent, .unreadable: nil
        }
      return MoneyCloseSummary(
        key: row.key, budgetName: name, closedOn: row.close.closedOn, outcome: row.close.outcome, deposited: row.close.deposited, result: row.close.result)
    }
  }
}
