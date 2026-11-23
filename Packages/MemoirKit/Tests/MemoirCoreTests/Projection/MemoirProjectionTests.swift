import Foundation
import GRDB
import ShadowCore
import ShadowStore
import Testing

@testable import MemoirCore

@Suite("Memoir replay projection", TestTimeLimit.standard)
struct MemoirProjectionTests {
  private static let start = LocalDate(daysSinceEpoch: ReplaySamples.firstDay)!
  private static let quest = ReplayFixture.quest

  private struct Device {
    let store: VaultStore
    let clock: MemoirTestClock
    let horizon: HorizonBox
    let reconciler: MemoirReconciler
  }

  private static func device(appVersion: String = "1") throws -> Device {
    let clock = MemoirTestClock()
    let horizon = HorizonBox()
    let reconciler = try MemoirReconciler(appVersion: appVersion, horizon: horizon.function)
    return Device(store: try MemoirStore.openInMemory(.main, wallClock: clock.function, projection: reconciler), clock: clock, horizon: horizon, reconciler: reconciler)
  }

  /// Creates the quest the day before `start`, then completes `start` plus each of `days`, one write a day with the store's clock a day further on.
  private static func live(_ days: [Int], on device: Device, firstNumber: Int = 1) async throws {
    let create = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(firstNumber), .questCreate(QuestCreation(questId: quest, schedule: try ProjectionSupport.routine(starting: start))),
      at: try ProjectionSupport.stamp(start, plus: -1))
    try await ProjectionSupport.append([create], to: device.store)
    for day in days {
      device.clock.advance(seconds: 86_400)
      let date = try #require(start.adding(days: day))
      let complete = try ProjectionSupport.command(
        MemoirStoreFixture.commandID(firstNumber + 1 + day), .questComplete(Occurrence(quest: quest, date: date)), at: try ProjectionSupport.stamp(start, plus: day))
      try await ProjectionSupport.append([complete], to: device.store)
    }
  }

  private static func expectProjected(_ device: Device, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let expected = try await ProjectionSupport.expected(in: device.store, through: device.horizon.function())
    #expect(try await ProjectionSupport.derived(in: device.store) == expected, "derived tables equal a full replay", sourceLocation: sourceLocation)
    try await ProjectionSupport.expectCheckpointsArePrefixReplays(in: device.store, stamp: device.reconciler.fingerprint, sourceLocation: sourceLocation)
  }

  private static func log(on offset: Int, in device: Device) async throws -> QuestLogRow? {
    let date = try #require(start.adding(days: offset))
    return try await device.store.read { transaction in try MemoirDerived.questLogs(on: date, in: transaction) }.first
  }

  @Test func shouldReopenAClosedDayWhenALateEarlierCommandArrivesAndRewriteItsRows() async throws {
    let device = try Self.device()
    try await Self.live([0, 1, 3, 4, 5, 6, 7, 8, 9], on: device)
    try await Self.expectProjected(device)
    #expect(try await Self.log(on: 2, in: device)?.entry.state == .missed, "the day nobody resolved closed with a miss")
    let checkpointsBefore = try await ProjectionSupport.checkpoints(in: device.store)
    #expect(checkpointsBefore.count >= 7)

    let offline = try MemoirStore.openInMemory(.main, wallClock: { Date(timeIntervalSince1970: 1_700_000_000 + 2 * 86_400 + 60) })
    let late = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(500), .questComplete(Occurrence(quest: Self.quest, date: try #require(Self.start.adding(days: 2)))),
      at: try ProjectionSupport.stamp(Self.start, plus: 2))
    try await ProjectionSupport.append([late], to: offline)
    _ = try await device.store.applyRemote(try await offline.pendingChanges(limit: Int.max).map(\.line))

    #expect(try await Self.log(on: 2, in: device)?.entry.isHold == true, "the completion replaces the miss on its own day")
    try await Self.expectProjected(device)
    let after = try await ProjectionSupport.checkpoints(in: device.store)
    let latePosition = try #require(try await ProjectionSupport.commands(in: device.store).first { $0.ref == late.ref }?.position)
    #expect(Set(after.filter { $0.position < latePosition }.map(\.digest)).isSubset(of: checkpointsBefore.map(\.digest)), "checkpoints before it are kept as they were")
    #expect(after.filter { $0.position > latePosition }.allSatisfy { checkpoint in !checkpointsBefore.contains(checkpoint) }, "checkpoints after it were rewritten")
  }

  @Test func shouldResumeStrictlyBeforeACheckpointWhoseOwnCommandIsPurged() async throws {
    let device = try Self.device()
    try await Self.live(Array(0..<8), on: device)
    let checkpoints = try await ProjectionSupport.checkpoints(in: device.store)
    let target = try #require(checkpoints.dropFirst(2).first)
    _ = try await device.store.write { transaction in try transaction.purge(target.position.ref) }

    #expect(try await ProjectionSupport.checkpoints(in: device.store).allSatisfy { $0.position != target.position })
    #expect(try await ProjectionSupport.indexedClocks(in: device.store)[target.position.ref.key.rawValue] == nil, "the purged command leaves the index")
    try await Self.expectProjected(device)
  }

  @Test func shouldKeepOnlyTheRecentCheckpointsAndTheLastOfEachMonth() async throws {
    let device = try Self.device()
    try await Self.live(Array(0..<100), on: device)
    let checkpoints = try await ProjectionSupport.checkpoints(in: device.store)
    let months = Set(checkpoints.map { $0.day.year * 12 + $0.day.month })
    #expect(checkpoints.count <= MemoirReconciler.recentCheckpoints + months.count)
    #expect(months.count >= 4)
    let latest = checkpoints.max { $0.position < $1.position }
    #expect(latest?.day == Self.start.adding(days: 98), "the newest checkpoint is the day the last command closed")
    try await Self.expectProjected(device)
  }

  @Test func shouldWalkTheViewToTheHorizonWithoutCheckpointingTheWalk() async throws {
    let device = try Self.device()
    try await Self.live([0, 1, 2], on: device)
    let before = try await ProjectionSupport.checkpoints(in: device.store)
    device.horizon.set(try ProjectionSupport.stamp(Self.start, plus: 6))
    try await device.reconciler.refresh(device.store)

    #expect(try await ProjectionSupport.checkpoints(in: device.store) == before, "the horizon closes days only in the view")
    #expect(try await Self.log(on: 4, in: device)?.entry.state == .missed)
    let hero = try await device.store.read { transaction in try MemoirDerived.hero(in: transaction) }
    #expect(hero?.openDay == Self.start.adding(days: 6))
    try await Self.expectProjected(device)

    let offline = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(600), .questComplete(Occurrence(quest: Self.quest, date: try #require(Self.start.adding(days: 3)))),
      at: try ProjectionSupport.stamp(Self.start, plus: 3))
    try await ProjectionSupport.append([offline], to: device.store)
    #expect(try await Self.log(on: 3, in: device)?.entry.isHold == true, "a command before the horizon but after every checkpoint lands on its day")
    #expect(try await Self.log(on: 4, in: device)?.entry.state == .missed)
    try await Self.expectProjected(device)
  }

  @Test func shouldSayTheAppNeedsAnUpdateWhenACommandNeedsAnUnknownRuleset() async throws {
    let device = try Self.device()
    try await Self.live([0, 1], on: device)
    let future = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(700), .recoveryComplete(RecoveryCompletion()), at: try ProjectionSupport.stamp(Self.start, plus: 2), rulesetVersion: 2)
    try await ProjectionSupport.append([future], to: device.store)

    let hero = try #require(try await device.store.read { transaction in try MemoirDerived.hero(in: transaction) })
    #expect(hero.needsAppUpdate)
    #expect(hero.halt == .rulesetUnavailable(command: future.id, version: 2))
    #expect(try await Self.log(on: 1, in: device)?.entry.isHold == true, "what replay took in before the halt stays shown")
    try await Self.expectProjected(device)
  }

  @Test func shouldDropEveryCheckpointAndRebuildWhenTheAppVersionChanges() async throws {
    let device = try Self.device(appVersion: "1")
    try await Self.live(Array(0..<5), on: device)
    let updated = try MemoirReconciler(appVersion: "2", horizon: device.horizon.function)
    #expect(updated.fingerprint != device.reconciler.fingerprint)
    _ = try await device.store.write { transaction in try updated.refresh(in: transaction.database) }

    let checkpoints = try await ProjectionSupport.checkpoints(in: device.store)
    #expect(!checkpoints.isEmpty)
    #expect(checkpoints.allSatisfy { $0.stamp == updated.fingerprint })
    try await ProjectionSupport.expectCheckpointsArePrefixReplays(in: device.store, stamp: updated.fingerprint)
    #expect(try await ProjectionSupport.derived(in: device.store) == ProjectionSupport.expected(in: device.store, through: nil))
  }

  @Test func shouldFallBackPastACheckpointThatNoLongerMatchesItsDigest() async throws {
    let device = try Self.device()
    try await Self.live(Array(0..<6), on: device)
    let latest = try #require(try await ProjectionSupport.checkpoints(in: device.store).max { $0.position < $1.position })
    _ = try await device.store.write { transaction in
      try transaction.database.execute(
        sql: "UPDATE \(ReplayCheckpointTable.table) SET digest = ? WHERE clock = ?", arguments: [String(repeating: "0", count: 64), latest.position.clock.description])
    }
    device.clock.advance(seconds: 86_400)
    let next = try ProjectionSupport.command(
      MemoirStoreFixture.commandID(800), .questComplete(Occurrence(quest: Self.quest, date: try #require(Self.start.adding(days: 6)))),
      at: try ProjectionSupport.stamp(Self.start, plus: 6))
    try await ProjectionSupport.append([next], to: device.store)

    #expect(try await ProjectionSupport.checkpoints(in: device.store).allSatisfy { $0.digest != String(repeating: "0", count: 64) }, "the refused row is deleted")
    try await Self.expectProjected(device)
  }

  @Test func shouldRebuildLocalTablesWithTheVaultScope() async throws {
    let device = try Self.device()
    try await Self.live(Array(0..<5), on: device)
    let clocksBefore = try await ProjectionSupport.indexedClocks(in: device.store)
    device.clock.advance(seconds: 3_600)
    try await device.store.remint(to: ReplicaID(UUID.v7(at: Date(timeIntervalSince1970: 1_800_000_000))), mode: .rebuild)

    let commands = try await ProjectionSupport.commands(in: device.store)
    let clocks = try await ProjectionSupport.indexedClocks(in: device.store)
    #expect(clocks == Dictionary(uniqueKeysWithValues: commands.map { ($0.ref.key.rawValue, $0.clock.description) }), "the index follows the restamped commands")
    #expect(clocks != clocksBefore)
    try await Self.expectProjected(device)
  }

  /// Every part of the fingerprint is hashed as canonical bytes, so it is the same in every process; update the literal deliberately when a part changes.
  @Test func shouldPinTheFingerprintSoEveryLaunchKeepsItsCheckpoints() throws {
    let fingerprint = try MemoirReconciler(appVersion: "1").fingerprint
    #expect(fingerprint == "29266ace12e66a1907f43eada56703a8c1be23663eee0b7a585f80e3936f308f")
    #expect(try MemoirReconciler(appVersion: "2").fingerprint != fingerprint)
  }

  @Test func shouldRefuseTheProjectionOnAStoreWithoutCommands() throws {
    let reconciler = try MemoirReconciler(appVersion: "1")
    #expect(throws: StoreError.self) { try MemoirStore.openInMemory(.restricted, projection: reconciler) }
  }
}
