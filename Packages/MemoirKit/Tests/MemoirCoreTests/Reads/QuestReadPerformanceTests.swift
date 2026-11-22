import Foundation
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir quest read performance", TestTimeLimit.standard)
struct QuestReadPerformanceTests {
  private static let questCount = 30
  private static let days = 730
  /// About 20 ms alone in a debug build; the budget leaves room for the suites running alongside, which slow it more than tenfold, and the comparison
  /// with a checkpoint decode, timed alternately under the same load, catches a load that starts scanning history.
  private static let todayBudget = Duration.seconds(1)

  /// Thirty daily quests over two years, each occurrence completed, skipped or rescheduled, appended in one write and projected once.
  private static func device() async throws -> ReadsDevice {
    let device = try ReadsDevice()
    let quests = (0..<questCount).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-0000000e%04x", $0)) }
    var commands = [MemoirCommand]()
    for (index, quest) in quests.enumerated() {
      commands.append(
        try device.command(
          .questCreate(QuestCreation(questId: quest, schedule: try ReadsDevice.schedule(.routine, start: 480 + index, duration: 20))), on: ReadsDevice.day(0),
          minute: 1))
    }
    for offset in 0..<days {
      let date = ReadsDevice.day(offset)
      for (index, quest) in quests.enumerated() {
        let occurrence = Occurrence(quest: quest, date: date)
        switch (offset + index) % 10 {
        case 0: commands.append(try device.command(.questSkip(QuestBreak(occurrence: occurrence, reasonTag: .travel)), on: date, minute: 400))
        case 1: commands.append(try device.command(.questReschedule(try QuestReschedule(occurrence: occurrence, toMinute: 600, reasonTag: .other)), on: date, minute: 400))
        default: commands.append(try device.command(.questComplete(occurrence), on: date, minute: 490))
        }
      }
    }
    try await device.append(commands)
    _ = try await device.store.write { transaction in
      for (index, quest) in quests.enumerated() { try QuestRecord(id: quest, name: "Quest \(index)").create(in: &transaction) }
    }
    try await device.walk(to: ReadsDevice.day(days))
    return device
  }

  @Test func shouldReadTodayWithinItsBudgetAfterTwoYearsOfThirtyQuests() async throws {
    let device = try await Self.device()
    let today = ReadsDevice.day(Self.days)
    let board = try await device.board(today)
    #expect(board.occurrences.count == Self.questCount && board.relation == .today)
    #expect(try await device.load(QuestList.self, QuestListQuery()).entries.count == Self.questCount)

    let checkpoint = try #require(try await ProjectionSupport.checkpoints(in: device.store).max { $0.position < $1.position })
    let clock = ContinuousClock()
    var times: (today: Duration, month: Duration, decode: Duration) = (.seconds(Int64.max), .seconds(Int64.max), .seconds(Int64.max))
    for _ in 0..<5 {
      var started = clock.now
      _ = try await device.board(today)
      times.today = min(times.today, clock.now - started)
      started = clock.now
      _ = try await device.load(PlanBoard.self, PlanBoardQuery(scope: .month(containing: today)))
      times.month = min(times.month, clock.now - started)
      started = clock.now
      _ = try checkpoint.state(expecting: device.reconciler.fingerprint)
      times.decode = min(times.decode, clock.now - started)
    }
    #expect(times.today * 5 < times.decode, "reading the derived rows (\(times.today)) beats decoding the latest checkpoint alone (\(times.decode))")
    #expect(times.today < Self.todayBudget, "the Today board took \(times.today)")
    #expect(times.month < Self.todayBudget * 2, "a month of the Plan took \(times.month)")
  }
}
