import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Synchronization
import Testing

@testable import MemoirCore

final class HorizonBox: Sendable {
  private let stamp = Mutex<IssueStamp?>(nil)

  var function: @Sendable () -> IssueStamp? { { self.stamp.withLock { $0 } } }

  func set(_ stamp: IssueStamp?) {
    self.stamp.withLock { $0 = stamp }
  }
}

enum ProjectionSupport {
  static let millisPerDay: Int64 = 86_400_000

  /// Midday UTC of the day `offset` days after `start`.
  static func stamp(_ start: LocalDate, plus offset: Int) throws -> IssueStamp {
    let day = try #require(start.adding(days: offset))
    return IssueStamp(instantMillis: Int64(day.daysSinceEpoch) * millisPerDay + 12 * 3_600_000, utcOffsetMinutes: 0, issuedOn: day)
  }

  static func command(_ id: UUID, _ body: MemoirCommandBody, at stamp: IssueStamp, rulesetVersion: Int = 1) throws -> MemoirCommand {
    try MemoirCommand(
      id: id, body: body, instantMillis: stamp.instantMillis, utcOffsetMinutes: stamp.utcOffsetMinutes, issuedOn: stamp.issuedOn, rulesetVersion: rulesetVersion)
  }

  static func append(_ commands: [MemoirCommand], to store: VaultStore) async throws {
    _ = try await store.write { transaction in for command in commands { try command.append(in: &transaction) } }
  }

  static func commands(in store: VaultStore) async throws -> [ReplayCommand] {
    try await store.read { transaction in try Replay.commands(in: transaction) }
  }

  static func derived(in store: VaultStore) async throws -> DerivedRows {
    try await store.read { transaction in try DerivedRows.stored(in: transaction.database) }
  }

  static func expected(in store: VaultStore, through horizon: IssueStamp?) async throws -> DerivedRows {
    DerivedRows(Replay.run(try await commands(in: store), through: horizon))
  }

  static func checkpoints(in store: VaultStore) async throws -> [ReplayCheckpoint] {
    try await store.read { transaction in
      try ReplayCheckpointTable.entries(in: transaction.database).compactMap { entry in try ReplayCheckpointTable.checkpoint(at: entry, in: transaction.database) }
    }
  }

  static func indexedClocks(in store: VaultStore) async throws -> [String: String] {
    try await store.read { transaction in
      guard try transaction.database.tableExists(ReplayCommandIndex.table) else { return [:] }
      return Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(transaction.database, sql: "SELECT key, clock FROM \(ReplayCommandIndex.table)").map { row in
          (row["key"] as String, row["clock"] as String)
        })
    }
  }

  /// Every checkpoint is the state a full replay of the commands up to its position gives, never one walked past it.
  static func expectCheckpointsArePrefixReplays(in store: VaultStore, stamp: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let commands = try await commands(in: store)
    for checkpoint in try await checkpoints(in: store) {
      let state = try checkpoint.state(expecting: stamp)
      #expect(state == Replay.run(commands.filter { $0.position <= checkpoint.position }), "checkpoint at \(checkpoint.day)", sourceLocation: sourceLocation)
    }
  }

  static func routine(starting start: LocalDate, strictness: Strictness = .routine) throws -> QuestSchedule {
    try QuestSchedule(
      strictness: strictness, startTimeMinutes: 480, durationMinutes: 60, statAffinity: .body, recurrence: try RecurrenceRule(frequency: .daily, startDate: start))
  }
}
