import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir projection performance", TestTimeLimit.standard)
struct ProjectionPerformanceTests {
  private static let questCount = 5
  private static let days = 365
  private static let start = LocalDate(daysSinceEpoch: ReplaySamples.firstDay)!
  private static let wallStart: TimeInterval = 1_700_000_000
  private static let lateDay = 40
  private static let batchDays = 30

  /// A year of five daily quests, written thirty days at a time with the store's clock moved on as far each time, then a completion for day 40 that another device
  /// made on that day and delivered a year late, which sorts before nearly every command and resumes from the checkpoint closing the month before.
  @Test func shouldReplayAYearFromTheMonthBeforeALateCommandNearTheStart() async throws {
    let clock = MemoirTestClock()
    let reconciler = try MemoirReconciler(appVersion: "1")
    let store = try MemoirStore.openInMemory(.main, wallClock: clock.function, projection: reconciler)
    let quests = (0..<Self.questCount).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-0000000e%04x", $0)) }
    var number = 0
    func next() -> UUID {
      number += 1
      return MemoirStoreFixture.commandID(number)
    }
    let creations = try quests.map { quest in
      try ProjectionSupport.command(
        next(), .questCreate(QuestCreation(questId: quest, schedule: try ProjectionSupport.routine(starting: Self.start))),
        at: try ProjectionSupport.stamp(Self.start, plus: -1))
    }
    try await ProjectionSupport.append(creations, to: store)
    for batchStart in stride(from: 0, to: Self.days, by: Self.batchDays) {
      var batch = [MemoirCommand]()
      for day in batchStart..<min(batchStart + Self.batchDays, Self.days) {
        let date = try #require(Self.start.adding(days: day))
        for quest in quests where day != Self.lateDay || quest != quests[0] {
          batch.append(try ProjectionSupport.command(next(), .questComplete(Occurrence(quest: quest, date: date)), at: try ProjectionSupport.stamp(Self.start, plus: day)))
        }
      }
      clock.advance(seconds: Double(Self.batchDays) * 86_400)
      try await ProjectionSupport.append(batch, to: store)
    }
    let checkpoints = try await ProjectionSupport.checkpoints(in: store)
    let months = Set(checkpoints.map { $0.day.year * 12 + $0.day.month })
    #expect(checkpoints.count <= MemoirReconciler.recentCheckpoints + months.count)
    #expect(months.count >= 12)

    let offline = try MemoirStore.openInMemory(.main, wallClock: { Date(timeIntervalSince1970: Self.wallStart + Double(Self.lateDay) * 86_400 + 60) })
    let lateCommand = try ProjectionSupport.command(
      next(), .questComplete(Occurrence(quest: quests[0], date: try #require(Self.start.adding(days: Self.lateDay)))),
      at: try ProjectionSupport.stamp(Self.start, plus: Self.lateDay))
    try await ProjectionSupport.append([lateCommand], to: offline)
    let lines = try await offline.pendingChanges(limit: Int.max).map(\.line)
    _ = try await store.applyRemote(lines)

    let commands = try await ProjectionSupport.commands(in: store)
    #expect(commands.count == Self.questCount * Self.days + Self.questCount)
    let latePosition = try #require(commands.first { $0.ref == lateCommand.ref }?.position)
    #expect(commands.filter { $0.position > latePosition }.count > commands.count * 8 / 10, "the late command sorts before nearly the whole year")
    let kept = try await ProjectionSupport.checkpoints(in: store).filter { $0.position < latePosition }
    #expect(!kept.isEmpty && kept.allSatisfy(checkpoints.contains), "the checkpoints before it are resumed from, not rewritten")
    #expect(try await ProjectionSupport.derived(in: store) == ProjectionSupport.expected(in: store, through: nil))
    let lateDate = try #require(Self.start.adding(days: Self.lateDay))
    let day = try await store.read { transaction in try MemoirDerived.questLogs(on: lateDate, in: transaction) }
    #expect(day.count == Self.questCount && day.allSatisfy(\.entry.isHold), "the late completion replaced the miss")

    let nextDay = try #require(Self.start.adding(days: Self.days))
    let completion = try ProjectionSupport.command(
      next(), .questComplete(Occurrence(quest: quests[1], date: nextDay)), at: try ProjectionSupport.stamp(Self.start, plus: Self.days))
    let early = try #require(commands.first { $0.position > latePosition && $0.ref != lateCommand.ref }?.ref)
    let (single, late) = try await store.write { transaction in
      var times: (single: Duration?, late: Duration?) = (nil, nil)
      for _ in 0..<5 {
        let single = try Self.reconcileTime(of: reconciler, in: &transaction) { transaction in
          try completion.append(in: &transaction)
          return completion.ref
        }
        times.single = min(times.single ?? .seconds(Int64.max), single)
        let late = try Self.reconcileTime(of: reconciler, in: &transaction) { transaction in
          _ = try transaction.purge(early)
          return early
        }
        times.late = min(times.late ?? .seconds(Int64.max), late)
      }
      return (times.single ?? .zero, times.late ?? .zero)
    }
    #expect(single * 3 < late, "one completion after a year (\(single)) costs a small part of replaying the year behind a change near its start (\(late))")
    #expect(try await ProjectionSupport.derived(in: store) == ProjectionSupport.expected(in: store, through: nil), "the timed changes were rolled back")
  }

  /// The reconcile alone of one change, rolled back afterwards: the first completion of a new day, which closes a day and saves a checkpoint, or a change
  /// near the start of the history, which replays the year from the checkpoint before it. Timed alternately and the fastest of each kept, both see the
  /// same load from suites running alongside.
  private static func reconcileTime(
    of reconciler: MemoirReconciler, in transaction: inout WriteTransaction, _ change: (inout WriteTransaction) throws -> EntityRef
  ) throws -> Duration {
    let database = transaction.database
    try database.execute(sql: "SAVEPOINT timed_change")
    let ref = try change(&transaction)
    let clock = ContinuousClock()
    let started = clock.now
    try reconciler.reconcile([ref], origin: .local, in: database)
    let elapsed = clock.now - started
    try database.execute(sql: "ROLLBACK TO timed_change")
    try database.execute(sql: "RELEASE timed_change")
    return elapsed
  }
}
