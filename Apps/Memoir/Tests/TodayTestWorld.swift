import Foundation
import MemoirCore
import ShadowCore
import ShadowStore
import Testing

@testable import Memoir

/// An in-memory vault on a hand-moved clock with the account's zone set to UTC, and a Today view model observing it.
@MainActor
final class TodayTestWorld {
  let clock: TestClock
  let opened: MemoirOpenedVault
  let context: MemoirScreenContext
  let model: TodayViewModel
  private var observing: Task<Void, Never>?

  init(day: Int = 0, minute: Int = 720) async throws {
    clock = TestClock(day: day, minute: minute)
    opened = try await MemoirVaultOpener.open(.inMemory, appVersion: "1", clock: clock.memoir(deviceZone: TestClock.utc))
    context = MemoirScreenContext(opened)
    try await context.writer.issue(try TestQuests.zone("UTC"))
    model = TodayViewModel(context: context)
  }

  func start() async throws {
    let model = model
    observing = Task { await model.observe() }
    try await TestClock.until("the first snapshot") { model.snapshot != nil }
  }

  func stop() {
    observing?.cancel()
  }

  var snapshot: TodaySnapshot {
    get throws { try #require(model.snapshot) }
  }

  @discardableResult
  func quest(
    _ name: String, strictness: Strictness = .routine, start: Int? = 480, frequency: RecurrenceRule.Frequency = .daily, from date: LocalDate = TestClock.day0
  ) async throws -> UUID {
    let id = UUID()
    let schedule = try QuestSchedule(
      strictness: strictness, startTimeMinutes: start, durationMinutes: 30, statAffinity: .body, recurrence: try RecurrenceRule(frequency: frequency, startDate: date))
    try await context.writer.issue(.questCreate(QuestCreation(questId: id, schedule: schedule)), creating: QuestRecord(id: id, name: name))
    return id
  }

  func row(_ quest: UUID, until what: String, _ condition: @escaping (BoardOccurrence) -> Bool = { _ in true }) async throws -> BoardOccurrence {
    let model = model
    try await TestClock.until(what) { model.snapshot?.board.occurrences.first { $0.quest.id == quest }.map(condition) == true }
    return try #require(model.snapshot?.board.occurrences.first { $0.quest.id == quest })
  }

  /// Walks the clock to `day` and refreshes the projection as the day turns do, then waits for the screen to follow: a read between the clock's move
  /// and the refresh already shows the new date, ahead of the open day.
  func turn(to day: Int, minute: Int = 720) async throws {
    clock.set(day: day, minute: minute)
    try await opened.refreshDay()
    let model = model
    try await TestClock.until("the screen to reach day \(day)") { model.snapshot.map { $0.today.date == TestClock.day(day) && $0.board.relation == .today } == true }
  }

  func bodies() async throws -> [MemoirCommandBody] {
    let entries = try await context.stores.main.read { transaction in try MemoirCommand.listing(in: transaction).entries }
    return try entries.sorted { $0.clock < $1.clock }.map { try MemoirCommandBody($0.record) }
  }

  func note(of body: MemoirCommandBody) async throws -> String? {
    guard let command = try await context.stores.commands().first(where: { (try? MemoirCommandBody($0)) == body }) else { return nil }
    return try await context.stores.main.read { transaction in try CommandNoteRecord.read(id: command.id, in: transaction).entry?.record.text }
  }

  func append(_ command: MemoirCommand) async throws {
    _ = try await context.stores.main.write { transaction in try command.append(in: &transaction) }
  }
}
