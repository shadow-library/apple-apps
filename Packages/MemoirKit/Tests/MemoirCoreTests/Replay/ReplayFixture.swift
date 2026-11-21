import Foundation
import ShadowCore
import ShadowStore

@testable import MemoirCore

enum ReplayFixture {
  static let replicaA = ReplicaID(MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000aaaaa"))
  static let replicaB = ReplicaID(MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-0000000bbbbb"))
  static let quest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000a001")
  static let secondQuest = MemoirStoreFixture.uuid("0190f3a0-0000-7000-8000-00000000a002")

  static func millis(_ text: String) throws -> Int64 {
    guard let millis = ReplayScenarioRun.millis(text) else { throw MemoirFixtureError(description: "\(text) is not an instant") }
    return millis
  }

  static func command(_ number: Int, _ body: MemoirCommandBody, at instant: String, offsetMinutes: Int = 0, rulesetVersion: Int = 1) throws -> MemoirCommand {
    let millis = try millis(instant)
    return try MemoirCommand(
      id: MemoirStoreFixture.commandID(number), body: body, instantMillis: millis, utcOffsetMinutes: offsetMinutes,
      issuedOn: try MemoirCommand.localDate(instantMillis: millis, utcOffsetMinutes: offsetMinutes), rulesetVersion: rulesetVersion)
  }

  static func entry(_ command: MemoirCommand, wall: Int64, replica: ReplicaID = replicaA, counter: UInt16 = 0) throws -> ReplayCommand {
    guard let clock = HLCTimestamp(wallMillis: wall, counter: counter, replica: replica) else { throw MemoirFixtureError(description: "clock \(wall)") }
    return .readable(AppendedEntry(record: command, clock: clock))
  }

  /// Commands clocked in the order given.
  static func entries(_ commands: [MemoirCommand], replica: ReplicaID = replicaA) throws -> [ReplayCommand] {
    try commands.enumerated().map { index, command in try entry(command, wall: Int64(index + 1), replica: replica) }
  }

  static func routine(starting start: String = "2026-03-01") throws -> QuestSchedule {
    try QuestSchedule(
      strictness: .routine, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body,
      recurrence: try RecurrenceRule(frequency: .daily, startDate: try MemoirStoreFixture.date(start)))
  }

  static func create(_ quest: UUID = quest, schedule: QuestSchedule) -> MemoirCommandBody {
    .questCreate(QuestCreation(questId: quest, schedule: schedule))
  }

  static func occurrence(_ date: String, of quest: UUID = quest) throws -> Occurrence {
    Occurrence(quest: quest, date: try MemoirStoreFixture.date(date))
  }

  static func state(coins: Int) -> ReplayState {
    var state = ReplayState.initial
    state.hero.coins = coins
    return state
  }
}
