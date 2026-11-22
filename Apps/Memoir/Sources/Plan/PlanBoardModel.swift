import Foundation
import MemoirCore
import Observation
import ShadowAppShell
import ShadowStore

nonisolated enum PlanPeriod: String, Hashable, Sendable, CaseIterable {
  case week
  case month
}

/// The board and, when the account has an open day, that day's board, whose lock summary says whether the plan can be locked or unlocked.
nonisolated struct PlanBoardSnapshot: ReplayReadModel {
  let board: PlanBoard
  let openDay: TodayBoard?

  static func load(_ query: PlanBoardQuery, in transaction: ReadTransaction) throws(StoreError) -> PlanBoardSnapshot {
    let board = try PlanBoard.load(query, in: transaction)
    let openDay = try board.openDay.map { day throws(StoreError) in try TodayBoard.load(TodayBoardQuery(date: day), in: transaction) }
    return PlanBoardSnapshot(board: board, openDay: openDay)
  }

  /// `isPlanEmpty` (`features/planning/index.tsx:27-29`).
  var isEmpty: Bool {
    board.days.allSatisfy { $0.occurrences.isEmpty } && (board.month ?? []).allSatisfy { $0.outcomes.isEmpty }
  }
}

/// The lock control beside the week (`features/planning/index.tsx:96-121`): only the week holding the open day offers it, and only as the open day's
/// board allows.
nonisolated enum PlanLockControl: Equatable, Sendable {
  case hidden
  case notThisWeek
  case lock(quests: [UUID], availability: ActionAvailability, capacity: LockCapacity?)
  case unlock(availability: ActionAvailability)

  init(_ snapshot: PlanBoardSnapshot, scope: PlanPeriod) {
    guard scope == .week else {
      self = .hidden
      return
    }
    guard let today = snapshot.openDay, snapshot.board.days.contains(where: { $0.date == today.date }) else {
      self = .notThisWeek
      return
    }
    let lock = today.lock
    if lock.state == .active {
      self = .unlock(availability: lock.unlock)
    } else {
      let quests = today.occurrences.filter { $0.isScheduled && $0.quest.isActive }.map(\.quest.id)
      self = .lock(quests: quests, availability: lock.lock, capacity: lock.capacity)
    }
  }

  var availability: ActionAvailability? {
    switch self {
    case .hidden, .notThisWeek: nil
    case .lock(_, let availability, _), .unlock(let availability): availability
    }
  }
}

@MainActor
@Observable
final class PlanBoardModel {
  private let context: MemoirScreenContext
  let snapshot = ReadObserver<PlanBoardSnapshot>()
  var scope = PlanPeriod.week
  private(set) var anchor: LocalDate?
  private(set) var today: LocalDate?
  private(set) var isLocking = false
  var failure: PresentedError?
  /// The account's day could not be read, so no board can be.
  private(set) var dayFailure: PresentedError?

  init(context: MemoirScreenContext) {
    self.context = context
  }

  var query: PlanBoardQuery? {
    anchor.map { PlanBoardQuery(scope: scope == .week ? .week(containing: $0) : .month(containing: $0)) }
  }

  var lockControl: PlanLockControl {
    snapshot.state.value.map { PlanLockControl($0, scope: scope) } ?? .hidden
  }

  /// Follows the account's day, so a turn moves "today" and a board still showing the old today along with it.
  func followToday() async {
    do {
      for try await day in context.observeToday() {
        if anchor == nil || anchor == today { anchor = day.date }
        today = day.date
      }
    } catch is CancellationError {
      return
    } catch {
      dayFailure = WritingErrors.presented(error) ?? PresentedError(error)
    }
  }

  func observe() async {
    guard let query else { return }
    let main = context.stores.main
    await snapshot.run { main.observe(PlanBoardSnapshot.self, query) }
  }

  func step(_ direction: Int) {
    guard let anchor else { return }
    self.anchor =
      switch scope {
      case .week: anchor.adding(days: direction * 7) ?? anchor
      case .month: anchor.adding(months: direction) ?? anchor
      }
  }

  func showToday() {
    anchor = today ?? anchor
  }

  /// `jumpToWeek` (`features/planning/index.tsx:43-47`).
  func showWeek(of date: LocalDate) {
    scope = .week
    anchor = date
  }

  /// Locks the open day's scheduled quests, or unlocks it, only when the open day's board allows it.
  @discardableResult
  func toggleLock() async -> Bool {
    let body: MemoirCommandBody
    switch lockControl {
    case .lock(let quests, .available, _):
      guard let lock = try? PlanLock(locking: quests) else { return false }
      body = .planSetLock(lock)
    case .unlock(.available):
      body = .planSetLock(.unlocked)
    case .hidden, .notThisWeek, .lock, .unlock:
      return false
    }
    guard !isLocking else { return false }
    isLocking = true
    defer { isLocking = false }
    failure = nil
    do {
      try await context.writer.issue(body)
      return true
    } catch {
      failure = WritingErrors.presented(error)
      return false
    }
  }
}
