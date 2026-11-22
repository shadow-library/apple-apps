import Foundation
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import MemoirCore

/// A main store with the projection, whose horizon a test moves by hand, and commands stamped at a minute of a day in UTC.
final class ReadsDevice: Sendable {
  static let monday = LocalDate(year: 2026, month: 3, day: 2)!
  static let anchor = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f001")
  static let routine = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f002")
  static let goal = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f003")
  static let optional = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000f004")

  let store: VaultStore
  let horizon: HorizonBox
  let reconciler: MemoirReconciler
  private let clock = MemoirTestClock()
  private let counter = Mutex(0)

  /// `open` opens the main store with the projection it is handed.
  init(open: ((MemoirReconciler) throws -> VaultStore)? = nil) throws {
    let horizon = HorizonBox()
    let reconciler = try MemoirReconciler(appVersion: "1", horizon: horizon.function)
    self.horizon = horizon
    self.reconciler = reconciler
    store = try open?(reconciler) ?? MemoirStore.openInMemory(.main, wallClock: clock.function, projection: reconciler)
  }

  static func day(_ offset: Int) -> LocalDate {
    monday.movedBy(days: offset)
  }

  static func stamp(_ day: LocalDate, minute: Int) -> IssueStamp {
    IssueStamp(instantMillis: Int64(day.daysSinceEpoch) * 86_400_000 + Int64(minute) * 60_000, utcOffsetMinutes: 0, issuedOn: day)
  }

  static func daily(from start: LocalDate = monday, interval: Int = 1) throws -> RecurrenceRule {
    try RecurrenceRule(frequency: .daily, interval: interval, startDate: start)
  }

  static func schedule(
    _ strictness: Strictness, start: Int? = nil, duration: Int = 30, stat: StatAffinity = .body, optIn: Bool = false, recurrence: RecurrenceRule? = nil
  ) throws -> QuestSchedule {
    try QuestSchedule(
      strictness: strictness, startTimeMinutes: start, durationMinutes: duration, statAffinity: stat, optionalStreakOptIn: optIn,
      recurrence: try recurrence ?? daily())
  }

  func command(_ body: MemoirCommandBody, on day: LocalDate, minute: Int = 600) throws -> MemoirCommand {
    let number = counter.withLock { value in
      value += 1
      return value
    }
    let stamp = Self.stamp(day, minute: minute)
    return try MemoirCommand(
      id: MemoirStoreFixture.commandID(number), body: body, instantMillis: stamp.instantMillis, utcOffsetMinutes: 0, issuedOn: day, rulesetVersion: 1)
  }

  @discardableResult
  func issue(_ body: MemoirCommandBody, on day: LocalDate, minute: Int = 600) async throws -> MemoirCommand {
    let command = try command(body, on: day, minute: minute)
    try await append([command])
    return command
  }

  func append(_ commands: [MemoirCommand]) async throws {
    clock.advance()
    _ = try await store.write { transaction in for command in commands { try command.append(in: &transaction) } }
  }

  func create(_ quest: UUID, _ name: String?, schedule: QuestSchedule, on day: LocalDate = monday) async throws {
    try await issue(.questCreate(QuestCreation(questId: quest, schedule: schedule)), on: day, minute: 1)
    guard let name else { return }
    _ = try await store.write { transaction in try QuestRecord(id: quest, name: name).create(in: &transaction) }
  }

  /// The four quests most tests share: an anchor at 07:00, a routine at 08:00 for an hour, a goal and an optional quest without a time.
  func createStandardQuests() async throws {
    try await create(Self.anchor, "Morning pages", schedule: try Self.schedule(.anchor, start: 420, duration: 30, stat: .mind))
    try await create(Self.routine, "Run", schedule: try Self.schedule(.routine, start: 480, duration: 60))
    try await create(Self.goal, "Budget review", schedule: try Self.schedule(.goal, duration: 45, stat: .wealth))
    try await create(Self.optional, "Stretch", schedule: try Self.schedule(.optional, duration: 15))
  }

  func walk(to day: LocalDate, minute: Int = 1) async throws {
    horizon.set(Self.stamp(day, minute: minute))
    try await reconciler.refresh(store)
  }

  func load<Model: ReplayReadModel>(_ model: Model.Type, _ query: Model.Query) async throws -> Model {
    try await store.load(model, query)
  }

  func board(_ day: LocalDate) async throws -> TodayBoard {
    try await load(TodayBoard.self, TodayBoardQuery(date: day))
  }

  func outcomes() async throws -> [UUID: ReplayOutcome] {
    Replay.run(try await store.read { transaction in try Replay.commands(in: transaction) }).outcomes
  }
}

extension TodayBoard {
  func occurrence(of quest: UUID) throws -> BoardOccurrence {
    try #require(occurrences.first { $0.quest.id == quest })
  }
}
