import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let aYear: TimeInterval = 365 * 86_400
private let note = EntityRef(kind: Fixture.note, key: Fixture.key("n1"))
private let other = EntityRef(kind: Fixture.note, key: Fixture.key("n2"))

private func kernelClock(_ store: VaultStore, _ column: String) async throws -> String? {
  try await store.read { transaction in try String.fetchOne(transaction.database, sql: "SELECT \(column) FROM kernel_state") }
}

private func title(_ store: VaultStore, _ ref: EntityRef) async throws -> JSONValue? {
  guard case .record(let state) = try await store.read({ try $0.state(of: ref) }) else { return nil }
  return state[field: "title"]?.value
}

@Suite("VaultStore clock floor")
struct StoreClockFloorTests {
  @Test("should leave observed unchanged by an echo of its own upload and, after rebuilding, still write above that acknowledged clock a year ahead")
  func shouldStayAboveAcknowledgedPollution() async throws {
    let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
    let store = try StoreFixture.open(clock: clock)
    let old = try await store.write { transaction in try transaction.set(note, ["title": "old"]) }
    try await store.dropChanges(through: 1)
    try await store.apply([old])
    #expect(try await kernelClock(store, "observed") == nil)
    #expect(try await kernelClock(store, "acknowledged") == old.clock.description)
    clock.set(ManualClock.start)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    let next = try await store.write { transaction in try transaction.set(other, ["title": "next"]) }
    #expect(next.clock > old.clock)
  }

  @Test("should keep a pending later edit above an acknowledged earlier one through a rebuild and a re-read")
  func shouldKeepLaterEditAfterRebuild() async throws {
    let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
    let store = try StoreFixture.open(clock: clock)
    let earlier = try await store.write { transaction in try transaction.set(note, ["title": "earlier"]) }
    try await store.dropChanges(through: 1)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "later"]) }
    clock.set(ManualClock.start)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    try await store.apply([earlier])
    #expect(try await title(store, note) == "later")
  }

  @Test("should shed the clock of unsent changes to the corrected wall time while staying above every observed clock")
  func shouldShedUnsentPollution() async throws {
    let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
    let store = try StoreFixture.open(clock: clock)
    let local = try await store.write { transaction in [try transaction.set(note, ["title": "a"]), try transaction.set(other, ["title": "b"])] }
    let wall = ManualClock(ManualClock.start).millis
    let remote = Fixture.change(
      .set, Fixture.note, Fixture.key("n3"), clock: must(HLCTimestamp(wallMillis: wall + 1_000, counter: 3, replica: Fixture.replicas[1]), "remote"), fields: ["title": "r"])
    try await store.apply([remote])
    clock.set(ManualClock.start)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    let rebuilt = try await store.allPending.map { try Stored.record($0.line) }
    #expect(rebuilt.count == 2)
    #expect(rebuilt.allSatisfy { $0.clock > remote.clock && $0.clock.wallMillis <= wall + 5_000 })
    #expect(zip(rebuilt, rebuilt.dropFirst()).allSatisfy { $0.clock < $1.clock })
    #expect(zip(local, rebuilt).allSatisfy { old, new in new.clock.wallMillis + 86_400_000 < old.clock.wallMillis })
  }

  @Test("should keep the acknowledged clock across reopening and both re-mint modes, never lowering it")
  func shouldKeepAcknowledgedClock() async throws {
    let directory = TemporaryDirectory()
    let replica = ReplicaID(UUID.v7())
    let acknowledged = try await {
      let store = try StoreFixture.open(at: .file(directory.storeURL))
      let written = try await store.write { transaction in try (1...3).map { try transaction.set(note, ["title": .int(Int64($0))]) } }
      #expect(try await kernelClock(store, "acknowledged") == nil)
      try await store.dropChanges(through: 2)
      #expect(try await kernelClock(store, "acknowledged") == written[1].clock.description)
      try await store.dropChanges(through: 1)
      try await store.dropChanges(through: 0)
      #expect(try await kernelClock(store, "acknowledged") == written[1].clock.description)
      let staleClock = must(HLCTimestamp(wallMillis: 1_000, counter: 0, replica: Fixture.replicas[0]), "stale")
      let stale = Fixture.change(.set, Fixture.note, Fixture.key("n9"), clock: staleClock, fields: ["title": "stale"])
      try await store.write { transaction in
        try transaction.database.execute(sql: "INSERT INTO change_log (seq, line) VALUES (0, ?)", arguments: [stale.canonicalBytes()])
      }
      try await store.dropChanges(through: 0)
      #expect(try await kernelClock(store, "acknowledged") == written[1].clock.description)
      return written[1].clock.description
    }()
    let reopened = try StoreFixture.open(at: .file(directory.storeURL))
    #expect(try await kernelClock(reopened, "acknowledged") == acknowledged)
    try await reopened.remint(to: replica, mode: .keepState)
    #expect(try await kernelClock(reopened, "acknowledged") == acknowledged)
    try await reopened.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    #expect(try await kernelClock(reopened, "acknowledged") == acknowledged)
    let next = try await reopened.write { transaction in try transaction.set(other, ["title": "next"]) }
    try await reopened.dropChanges(through: Int64.max)
    #expect(try await kernelClock(reopened, "acknowledged") == next.clock.description)
  }

  @Test("should count a record of a previous replica id as observed but never an echo under the current one")
  func shouldSkipOnlyCurrentReplicaEchoes() async throws {
    let store = try StoreFixture.open()
    let own = try await store.write { transaction in try transaction.set(note, ["title": "own"]) }
    try await store.apply([own])
    #expect(try await kernelClock(store, "observed") == nil)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .keepState)
    try await store.apply([own])
    #expect(try await kernelClock(store, "observed") == own.clock.description)
    let current = try await store.write { transaction in try transaction.set(other, ["title": "current"]) }
    try await store.apply([current])
    #expect(try await kernelClock(store, "observed") == own.clock.description)
  }
}
