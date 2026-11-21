import Foundation
import ShadowCore
import Testing

@testable import MemoirCore

@Suite("Memoir replay performance", TestTimeLimit.standard)
struct ReplayPerformanceTests {
  private static let questCount = 30

  /// Thirty daily quests, each occurrence completed, skipped or rescheduled, with the walk closing every day.
  private static func commands(days dayCount: Int) throws -> [ReplayCommand] {
    let start = try MemoirStoreFixture.date("2025-01-01")
    let recurrence = try RecurrenceRule(frequency: .daily, startDate: start)
    let quests = (0..<questCount).map { MemoirStoreFixture.uuid(String(format: "0190f3a0-0000-7000-8000-0000000d%04x", $0)) }
    var bodies = try quests.map { quest in
      (
        MemoirCommandBody.questCreate(
          QuestCreation(questId: quest, schedule: try QuestSchedule(strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: recurrence))),
        start
      )
    }
    for offset in 0..<dayCount {
      let date = try #require(start.adding(days: offset))
      for (index, quest) in quests.enumerated() {
        let occurrence = Occurrence(quest: quest, date: date)
        switch (offset + index) % 10 {
        case 0: bodies.append((.questSkip(QuestBreak(occurrence: occurrence, reasonTag: .travel)), date))
        case 1: bodies.append((.questReschedule(try QuestReschedule(occurrence: occurrence, toMinute: 600, reasonTag: .other)), date))
        default: bodies.append((.questComplete(occurrence), date))
        }
      }
    }
    return try bodies.enumerated().map { index, entry in
      let instant = Int64(entry.1.daysSinceEpoch) * 86_400_000 + 8 * 3_600_000 + Int64(index % 1_000)
      let command = try MemoirCommand(
        id: MemoirStoreFixture.commandID(index + 1), body: entry.0, instantMillis: instant, utcOffsetMinutes: 0,
        issuedOn: try MemoirCommand.localDate(instantMillis: instant, utcOffsetMinutes: 0), rulesetVersion: 1)
      return try ReplayFixture.entry(command, wall: Int64(index + 1))
    }
  }

  /// The fastest of five runs of each history, taken alternately, so both see the same load from suites running alongside and one slow run decides
  /// nothing.
  private static func fastest(_ short: [ReplayCommand], _ long: [ReplayCommand]) -> (short: Duration, long: Duration, state: ReplayState) {
    let clock = ContinuousClock()
    var times: (short: Duration?, long: Duration?) = (nil, nil)
    var state = ReplayState.initial
    for _ in 0..<5 {
      var started = clock.now
      _ = Replay.run(short)
      times.short = min(times.short ?? .seconds(Int64.max), clock.now - started)
      started = clock.now
      state = Replay.run(long)
      times.long = min(times.long ?? .seconds(Int64.max), clock.now - started)
    }
    return (times.short ?? .zero, times.long ?? .zero, state)
  }

  @Test func shouldReplayAndWalkInTimeLinearInTheDaysOfHistory() throws {
    let half = try Self.commands(days: 200)
    let full = try Self.commands(days: 400)
    #expect(full.count >= 12_000)
    let (short, long, state) = Self.fastest(half, full)
    #expect(state.outcomes.count == full.count)
    #expect(state.logs.count == Self.questCount * 400)
    #expect(state.days.values.count(where: \.isClosed) == 399)
    #expect(state.logs.all.allSatisfy { $0.value.state != .missed }, "every occurrence has its own outcome before its day closes")
    #expect(long / short < 3, "twice the history took \(long) against \(short)")
    #expect(long < .seconds(300), "a backstop well inside the standard tier: \(long)")
  }
}
