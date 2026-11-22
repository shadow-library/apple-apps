import Foundation
import MemoirCore
import Testing

@testable import Memoir

/// In-memory screens at noon of `TestClock.day0` in UTC, with quests made the way the builder makes them.
@MainActor
enum QuestsTesting {
  static func context(_ clock: TestClock = TestClock(day: 0, minute: 720)) throws -> MemoirScreenContext {
    try MemoirScreenContext.inMemory(clock: clock.memoir(deviceZone: TestClock.utc))
  }

  @discardableResult
  static func quest(
    _ name: String, strictness: Strictness = .routine, start: Int? = 480, duration: Int = 30, frequency: RecurrenceRule.Frequency = .daily,
    in context: MemoirScreenContext
  ) async throws -> UUID {
    let id = UUID()
    let schedule = try QuestSchedule(
      strictness: strictness, startTimeMinutes: start, durationMinutes: duration, statAffinity: .body,
      recurrence: try RecurrenceRule(frequency: frequency, startDate: TestClock.day0))
    try await context.writer.issue(.questCreate(QuestCreation(questId: id, schedule: schedule)), creating: QuestRecord(id: id, name: name))
    return id
  }

  static func bodies(in context: MemoirScreenContext) async throws -> [MemoirCommandBody] {
    try await context.stores.commands().map { try MemoirCommandBody($0) }
  }

  static func record(_ id: UUID, in context: MemoirScreenContext) async throws -> QuestRecord? {
    try await context.stores.quests().first { $0.id == id }
  }
}

/// A view's `.task`: `start` runs while `during` runs its body, and is cancelled after.
@MainActor
struct QuestsObservation {
  let start: @MainActor () async -> Void

  init(_ start: @escaping @MainActor () async -> Void) {
    self.start = start
  }

  func during<Value>(_ body: () async throws -> Value) async rethrows -> Value {
    let task = Task { @MainActor in await start() }
    defer { task.cancel() }
    return try await body()
  }
}
