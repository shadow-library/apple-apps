import Foundation
import MemoirCore
import ShadowStore
import Synchronization
import Testing

@testable import Memoir

/// A wall clock the test moves by hand, standing in for the trusted clock: it runs months behind the device's, so a stamp taken from `Date()` shows.
nonisolated final class TestClock: Sendable {
  static let day0 = LocalDate(isoString: "2026-03-02")!
  static let utc = TimeZone(identifier: "UTC")!
  static let berlin = TimeZone(identifier: "Europe/Berlin")!

  private let current: Mutex<Date>

  init(_ start: Date) {
    current = Mutex(start)
  }

  convenience init(day: Int, minute: Int) {
    self.init(Self.date(day: day, minute: minute))
  }

  var now: @Sendable () -> Date { { self.current.withLock { $0 } } }

  func set(day: Int, minute: Int) {
    current.withLock { $0 = Self.date(day: day, minute: minute) }
  }

  func memoir(deviceZone: TimeZone, waitUntil: (@Sendable (Date) async throws -> Void)? = nil) -> MemoirClock {
    MemoirClock(now: now, deviceZone: { deviceZone }, waitUntil: waitUntil)
  }

  static func day(_ offset: Int) -> LocalDate {
    day0.adding(days: offset)!
  }

  /// The instant `minute` minutes into day `day` after `day0`, in UTC.
  static func date(day: Int, minute: Int) -> Date {
    Date(timeIntervalSince1970: Double(millis(day: day, minute: minute)) / 1000)
  }

  static func millis(day: Int, minute: Int) -> Int64 {
    try! IssueClock(timeZone: utc).startOfDay(Self.day(day)) + Int64(minute) * 60_000
  }

  static func until(_ what: String, _ condition: @MainActor () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline {
      if try await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting: \(what)")
  }
}

/// A day turns wait that records each deadline and then holds until it is cancelled, as a real wait would until midnight.
nonisolated final class HeldWaits: Sendable {
  private let state = Mutex((deadlines: [Date](), cancelled: 0))

  var deadlines: [Date] { state.withLock { $0.deadlines } }
  var cancelled: Int { state.withLock { $0.cancelled } }

  var wait: @Sendable (Date) async throws -> Void {
    { deadline in
      self.state.withLock { $0.deadlines.append(deadline) }
      do {
        try await Task.sleep(for: .seconds(3_600))
      } catch {
        self.state.withLock { $0.cancelled += 1 }
        throw error
      }
    }
  }
}

nonisolated final class Recorded<Value: Sendable>: Sendable {
  private let recorded = Mutex<[Value]>([])

  var values: [Value] { recorded.withLock { $0 } }

  func append(_ value: Value) {
    recorded.withLock { $0.append(value) }
  }
}

extension MemoirStores {
  func openDay() async throws -> LocalDate? {
    try await main.read { transaction in try MemoirDerived.hero(in: transaction)?.openDay }
  }

  func commands() async throws -> [MemoirCommand] {
    try await main.read { transaction in try MemoirCommand.listing(in: transaction).entries.map(\.record) }
  }

  func quests() async throws -> [QuestRecord] {
    try await main.read { transaction in try QuestRecord.listing(in: transaction).entries.map(\.record) }
  }
}

enum TestQuests {
  static func creation(_ id: UUID, from date: LocalDate = TestClock.day0) throws -> MemoirCommandBody {
    let schedule = try QuestSchedule(
      strictness: .routine, startTimeMinutes: 480, durationMinutes: 30, statAffinity: .body, recurrence: try RecurrenceRule(frequency: .daily, startDate: date))
    return .questCreate(QuestCreation(questId: id, schedule: schedule))
  }

  static func zone(_ identifier: String) throws -> MemoirCommandBody {
    .accountSetTimeZone(try TimeZoneChange(identifier: identifier))
  }
}
