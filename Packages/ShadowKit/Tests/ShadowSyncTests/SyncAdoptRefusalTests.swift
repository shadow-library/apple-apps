import Foundation
import GRDB
import ShadowCore
import ShadowKeychain
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowSync

enum SyncUnfoldable: CaseIterable, Sendable {
  case unknownKey
  case failedAuthentication
  case newerFormat
  case clockAhead
}

/// A replica planted with a readable first segment and a second one that cannot be folded until `repair` runs; a clock-ahead change stays ahead through the adoption delay.
private struct SyncPlantedReplica {
  let replica: ReplicaID
  let first: ObjectKey
  let second: ObjectKey
  let repair: @Sendable () async throws -> Void

  static func plant(_ cause: SyncUnfoldable, in scenario: SyncAdoptScenario) async throws -> SyncPlantedReplica {
    let world = scenario.world
    let ahead: TimeInterval = cause == .clockAhead ? 34 * SyncDays.day : 0
    let clock = world.clock
    let offset = Mutex<TimeInterval>(0)
    let writer = try SyncFixture.open(wallClock: { clock.now.addingTimeInterval(offset.withLock { $0 }) })
    let replica = writer.replica
    for index in 0..<2 {
      if index == 1 { offset.withLock { $0 = ahead } }
      _ = try await writer.write { transaction in
        try transaction.set(EntityRef(kind: SyncFixture.note, key: ReplicaFixture.key("q\(index)")), ["title": .string("planted \(index)")])
      }
    }
    let lines = try await writer.pendingChanges(limit: .max).map(\.line)
    let shared = try #require(scenario.retired.ring.writingKey())
    let first = try await SyncPlant.segment([lines[0]], replica: replica, key: shared, in: scenario.log)
    let foreign = KeyRing(vault: SyncFixture.vault, store: InMemoryKeychain().device("stranger").store(service: "keys", scope: .synced))
    let sealingKey = cause == .unknownKey ? try foreign.createKey() : shared
    guard let header = SegmentHeader(replica: replica, first: 2, last: 2, previous: StreamPoint(last: 1, tag: first.tag), dependencies: [:], schema: 3),
      let file = SegmentFile(header: header, lines: [lines[1]])
    else { throw SyncFixtureFailure("the planted segment is invalid") }
    let sealed = try SegmentCodec.seal(file, vault: SyncFixture.vault, with: sealingKey)
    var data = sealed.data
    switch cause {
    case .failedAuthentication: data[data.endIndex - 1] ^= 0x01
    case .newerFormat: data[data.startIndex + 4] = VaultFormat.version + 1
    case .unknownKey, .clockAhead: break
    }
    let log = scenario.log
    _ = try await log.put(sealed.key, data: data, condition: .overwrite)
    let retiredRing = scenario.retired.ring
    let keychain = world.keychain
    let repair: @Sendable () async throws -> Void = {
      switch cause {
      case .unknownKey:
        try retiredRing.add(sealingKey)
        keychain.deliver()
      case .failedAuthentication, .newerFormat:
        _ = try await log.put(sealed.key, data: sealed.data, condition: .overwrite)
      case .clockAhead:
        clock.set(clock.now.addingTimeInterval(3 * SyncDays.day))
      }
    }
    return SyncPlantedReplica(replica: replica, first: first.key, second: sealed.key, repair: repair)
  }
}

private func count(_ table: String, in store: VaultStore) async throws -> Int {
  try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
}

@Suite("SyncEngine adoption of files it cannot fold yet")
struct SyncAdoptRefusalTests {
  @Test("should fold up to a file it cannot read, delete nothing of that replica, adopt the others, and finish once the cause clears", arguments: SyncUnfoldable.allCases)
  func shouldWaitForUnfoldableFile(_ cause: SyncUnfoldable) async throws {
    let scenario = try await SyncAdoptScenario.make()
    let planted = try await SyncPlantedReplica.plant(cause, in: scenario)
    try await scenario.adopter.lifecycle.retire(planted.replica, successor: scenario.adopterID)
    scenario.world.advance(days: 31)
    _ = try await scenario.adopter.engine.upload()

    #expect(try await scenario.adopter.engine.adopt() == .progressed(adopted: [scenario.retiredID], waiting: [planted.replica]))
    #expect(try await scenario.adopter.engine.adopt() == .inProgress([planted.replica]))

    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    #expect(Set(try await SyncAdoptCheck.stored(under: planted.replica, in: scenario.log)) == [planted.first, planted.second])
    #expect(!scenario.adopterProvider.deleted.contains { $0.hasPrefix(VaultPath.replicaPrefix(planted.replica)) })
    #expect(Set(try await SyncAdoptCheck.folds(scenario.adopter)[planted.replica]?.keys.map(\.self) ?? []) == [planted.first])
    #expect(try await SyncAdoptCheck.rows(scenario.adopter)[planted.replica]?.phase == .folding)
    #expect(!(try await SyncAdoptCheck.facts(scenario.adopter)).contains { $0.adopted == planted.replica })

    try await planted.repair()

    #expect(try await scenario.adopter.engine.adopt() == .adopted([planted.replica]))
    #expect(try await SyncAdoptCheck.stored(under: planted.replica, in: scenario.log).isEmpty)
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
  }

  @Test("should re-mint like a download when a file carries a change stamped with its own id, forget every row and adopt again under the new id")
  func shouldRemintOnCollision() async throws {
    let scenario = try await SyncAdoptScenario.make()
    let old = scenario.adopterID
    try await scenario.adopter.writeNotes(1, prefix: "mine-")
    let mine = try await scenario.adopter.pendingLines()
    _ = try await scenario.adopter.uploaded()
    let other = ReplicaID(UUID.v7())
    _ = try await SyncPlant.segment(mine, replica: other, key: try #require(scenario.adopter.ring.writingKey()), in: scenario.log)
    try await scenario.adopter.lifecycle.retire(other, successor: old)
    scenario.world.advance(days: 31)
    _ = try await scenario.adopter.engine.upload()

    #expect(try await scenario.adopter.engine.adopt() == .postponed)

    #expect(scenario.adopterStore.replica != old)
    #expect(try await count("sync_adoption", in: scenario.adopterStore) == 0)
    #expect(try await count("sync_adoption_fold", in: scenario.adopterStore) == 0)
    #expect(!scenario.adopterProvider.deleted.contains { $0.hasPrefix(VaultPath.replicaPrefix(scenario.retiredID)) || $0.hasPrefix(VaultPath.replicaPrefix(other)) })

    let outcomes = try await SyncAdoptCheck.finish(scenario.adopter)
    #expect(outcomes.first == .adopted([other, scenario.retiredID].sorted()))
    #expect(try await SyncAdoptCheck.stored(under: scenario.retiredID, in: scenario.log).isEmpty)
    #expect(try await SyncAdoptCheck.stored(under: other, in: scenario.log).isEmpty)
    _ = try await scenario.adopter.engine.sync()
    try await scenario.expectConverges(try await scenario.freshReader("fresh"), "fresh")
    try await scenario.expectConverges(scenario.half, "half")
  }
}
