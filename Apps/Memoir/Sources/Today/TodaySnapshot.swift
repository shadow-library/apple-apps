import Foundation
import MemoirCore
import ShadowStore

nonisolated struct TodayHero: Sendable, Equatable {
  let name: HeroName
  let level: LevelProgress
  let coins: Int
  let momentum: HeroMomentum
}

/// What the Today screen shows, read in one transaction so the account's day, its board and the hero always agree; a projection refresh at the day turn
/// commits, so the read runs again and moves to the new day.
nonisolated struct TodaySnapshot: Sendable, Equatable {
  static let tomorrowLimit = 2

  let today: MemoirToday
  let zone: AccountZone
  let board: TodayBoard
  let hero: TodayHero
  let streaks: StreakBoard
  let tomorrow: [BoardOccurrence]

  /// The streak board lists the active quests, so it is empty exactly when there are none.
  var hasActiveQuests: Bool { !streaks.entries.isEmpty }

  static func load(in transaction: ReadTransaction, clock: MemoirClock) throws -> TodaySnapshot {
    let zone = try AccountZone.load(in: transaction)
    let today = try clock.today(in: zone)
    let board = try TodayBoard.load(TodayBoardQuery(date: today.date), in: transaction)
    let deck = try HeroDeck.load(HeroDeckQuery(eventLimit: 0), in: transaction)
    let streaks = try StreakBoard.load(StreakBoardQuery(date: today.date), in: transaction)
    var tomorrow = [BoardOccurrence]()
    if let next = today.date.adding(days: 1) {
      tomorrow = Array(try TodayBoard.load(TodayBoardQuery(date: next), in: transaction).occurrences.filter(\.isScheduled).prefix(tomorrowLimit))
    }
    return TodaySnapshot(
      today: today, zone: zone, board: board, hero: TodayHero(name: deck.name, level: deck.level, coins: deck.coins, momentum: deck.momentum),
      streaks: streaks, tomorrow: tomorrow)
  }
}

/// What the screen says above everything else: the account's zone this device cannot read, a replay that stopped, and what replay withdrew.
enum TodayNotice: Hashable {
  case unknownZone(identifier: String, fallbackOffsetMinutes: Int?)
  case needsAppUpdate
  case purchaseWithdrawn(balance: Int, price: Int)
}

/// The quest list's place: the day's quests, nothing due today among active quests, or no quest yet.
enum TodayContent: Equatable {
  case quests
  case nothingDue(NextOccurrence?)
  case firstDay
}

/// The end-of-day note (`fixture-provider.ts:296-312`).
struct TodayDayEnd: Equatable {
  let scheduled: Int
  let kept: Int
  let partial: Int
  let skipped: Int
}

extension TodaySnapshot {
  var notices: [TodayNotice] {
    var notices = [TodayNotice]()
    if case .unknownZone(let identifier, let offset) = today.source { notices.append(.unknownZone(identifier: identifier, fallbackOffsetMinutes: offset)) }
    if board.halt != nil { notices.append(.needsAppUpdate) }
    for notice in board.notices {
      switch notice {
      case .purchaseWithdrawn(_, _, let balance, let price): notices.append(.purchaseWithdrawn(balance: balance, price: price))
      }
    }
    return notices
  }

  var content: TodayContent {
    guard board.occurrences.isEmpty else { return .quests }
    return hasActiveQuests ? .nothingDue(board.nextScheduled) : .firstDay
  }

  /// Minutes of the owner's wake window left at `instantMillis`, only on the account's open day: another day's remaining time is not a fact about now.
  func minutesUntilSleep(at instantMillis: Int64, deviceZone: TimeZone) -> Int? {
    guard board.relation == .today else { return nil }
    let minute = zone.resolve(at: instantMillis, device: deviceZone).clock.minuteOfDay(at: instantMillis)
    return board.scheduleWindow.minutesUntilSleep(from: minute)
  }

  func minuteOfDay(at instantMillis: Int64, deviceZone: TimeZone) -> Int {
    zone.resolve(at: instantMillis, device: deviceZone).clock.minuteOfDay(at: instantMillis)
  }

  func dayEnd(minutesUntilSleep: Int?) -> TodayDayEnd? {
    let ended = board.relation == .past || (minutesUntilSleep.map { $0 <= 0 } ?? false)
    let scheduled = board.occurrences.filter(\.isScheduled)
    guard ended, !scheduled.isEmpty, !scheduled.allSatisfy({ $0.effectiveState == nil }) else { return nil }
    let tally = board.tally
    return TodayDayEnd(scheduled: tally.scheduled, kept: tally.kept, partial: tally.partial, skipped: tally.skipped)
  }

  func occurrence(_ id: Occurrence) -> BoardOccurrence? {
    board.occurrences.first { $0.id == id } ?? tomorrow.first { $0.id == id }
  }
}
