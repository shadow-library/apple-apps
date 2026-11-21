import Foundation
import ShadowCore
import Testing

@testable import MemoirCore

@Suite("Memoir replay performance", TestTimeLimit.standard)
struct ReplayPerformanceTests {
  private static let questCount = 50
  private static let dayCount = 400

  /// Fifty daily quests over 400 days, each occurrence completed, skipped or rescheduled: a long life of commands.
  private static func commands() throws -> [ReplayCommand] {
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

  @Test func shouldReplayTwentyThousandCommandsInLinearTime() throws {
    let commands = try Self.commands()
    #expect(commands.count >= 20_000)
    let clock = ContinuousClock()
    let started = clock.now
    let state = Replay.run(commands)
    let elapsed = clock.now - started
    #expect(state.outcomes.count == commands.count)
    #expect(state.logs.count == Self.questCount * Self.dayCount)
    #expect(elapsed < .seconds(60), "replay took \(elapsed)")
  }
}
