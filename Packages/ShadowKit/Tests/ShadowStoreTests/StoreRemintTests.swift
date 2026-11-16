import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let fresh = EntityRef(kind: Fixture.note, key: Fixture.key("fresh"))
private let aYear: TimeInterval = 365 * 86_400

private let projection = StoreMigration(identifier: "product.projection") { db in
  try db.execute(sql: "CREATE TABLE projection (id INTEGER PRIMARY KEY, label TEXT NOT NULL)")
}

private struct AlsoFailure: Error {}

private struct Snapshot: Equatable {
  let replica: ReplicaID
  let vault: String
  let own: String
  let pending: [LoggedChange]
  let projected: Int

  init(_ store: VaultStore) async throws {
    replica = store.replica
    vault = try await store.loadState(.vault).digest
    own = try await store.loadState(.own).digest
    pending = try await store.allPending
    projected = try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM projection") ?? -1 }
  }
}

private func newReplica() -> ReplicaID {
  ReplicaID(UUID.v7())
}

private func records(_ pending: [LoggedChange]) throws -> [ChangeRecord] {
  try pending.map { try Stored.record($0.line) }
}

private struct History {
  let store: VaultStore
  let local: [ChangeRecord]
  let remote: [ChangeRecord]
  let dropped: Int
}

private func makeHistory(_ generator: inout SeededGenerator, clock: ManualClock) async throws -> History {
  let store = try VaultStore.open(.inMemory, registry: Fixture.v2, migrations: [projection], wallClock: clock.function)
  var factory = ChangeFactory()
  var known = [EntityRef: [String]]()
  var local = [ChangeRecord]()
  var remote = [ChangeRecord]()
  for _ in 0..<generator.int(in: 1...4) {
    let result = try await runLocal((0..<generator.int(in: 1...8)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
    local += result.records
    known = result.known
    let records = factory.changes(&generator, count: 0...6)
    try await store.apply(records)
    remote += records
  }
  try await store.write { transaction in try transaction.database.execute(sql: "INSERT INTO projection (label) VALUES ('row')") }
  let dropped = generator.int(in: 0...local.count)
  try await store.dropChanges(through: Int64(dropped))
  return History(store: store, local: local, remote: remote, dropped: dropped)
}

@Suite("VaultStore re-mint")
struct StoreRemintTests {
  @Test("should keep the vault scope and rebuild the own scope from the pending changes when keeping state")
  func shouldKeepState() async throws {
    try await forAll(iterations: 100) { generator in
      let clock = ManualClock()
      let history = try await makeHistory(&generator, clock: clock)
      let store = history.store
      let before = try await Snapshot(store)
      let pending = Array(history.local.dropFirst(history.dropped))
      let replica = newReplica()
      try await store.remint(to: replica, mode: .keepState)
      try #require(store.replica == replica)
      try #require(try await store.loadState(.vault).digest == before.vault)
      try #require(try await store.loadState(.own).digest == Fixture.state(pending, Fixture.v2).retained(registry: Fixture.v2).digest)
      try #require(try await store.allPending == StoreFixture.logged(pending))
      let next = try await store.write { transaction in try transaction.set(fresh, ["title": "next"]) }
      try #require(next.clock.replica == replica)
      try #require((history.local + history.remote).allSatisfy { $0.clock < next.clock })
      try #require(try await store.allPending.last == LoggedChange(sequence: Int64(pending.count) + 1, line: next.canonicalBytes()))
    }
  }

  @Test("should re-create the pending changes with fresh clocks above every acknowledged change and rebuild both scopes from them")
  func shouldRebuild() async throws {
    try await forAll(iterations: 100) { generator in
      let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
      let history = try await makeHistory(&generator, clock: clock)
      let store = history.store
      let pending = Array(history.local.dropFirst(history.dropped))
      let acknowledged = history.local.prefix(history.dropped).map(\.clock).max()
      clock.set(ManualClock.start)
      let floor = clock.millis
      let replica = newReplica()
      try await store.remint(to: replica, mode: .rebuild) { db in
        let current = try String.fetchOne(db, sql: "SELECT replica FROM kernel_state")
        guard db.isInsideTransaction, current == replica.description else { throw AlsoFailure() }
        try db.execute(sql: "DELETE FROM projection")
      }
      let rebuilt = try records(try await store.allPending)
      try #require(try await store.allPending.map(\.sequence) == (0..<rebuilt.count).map { Int64($0) + 1 })
      try #require(rebuilt.count == pending.count)
      for (old, new) in zip(pending, rebuilt) {
        try #require(new.entity == old.entity && new.key == old.key && new.kind == old.kind && new.schema == old.schema)
        try #require(CanonicalJSON.encode(.object(new.fields)) == CanonicalJSON.encode(.object(old.fields)))
        try #require(new.id != old.id && new.clock.wallMillis >= floor && new.clock.replica == replica)
        try #require(acknowledged.map { new.clock > $0 } ?? (new.clock < old.clock))
      }
      try #require(zip(rebuilt, rebuilt.dropFirst()).allSatisfy { $0.clock < $1.clock })
      let expected = Fixture.state(rebuilt, Fixture.v2).retained(registry: Fixture.v2).digest
      try #require(try await store.loadState(.vault).digest == expected)
      try #require(try await store.loadState(.own).digest == expected)
      try #require(try await Snapshot(store).projected == 0)
      let next = try await store.write { transaction in try transaction.set(fresh, ["title": "next"]) }
      try #require(rebuilt.allSatisfy { $0.clock < next.clock } && next.clock.replica == replica)
    }
  }

  @Test("should keep revision ids when rebuilding")
  func shouldKeepRevisionIDs() async throws {
    let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
    let store = try StoreFixture.open(clock: clock)
    let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
    let (first, firstID, secondID) = try await store.write { transaction in
      let (record, first) = try transaction.revise(draft, body: "one")
      let (_, second) = try transaction.revise(draft, body: "two", marks: ["approved"])
      _ = try transaction.reassert(draft, revision: first, head: true)
      return (record, first, second)
    }
    clock.set(ManualClock.start)
    try await store.remint(to: newReplica(), mode: .rebuild)
    guard case .revisioned(let state) = try await store.read({ try $0.state(of: draft) }) else { throw StoreTestFailure.unexpectedState }
    #expect(Set(state.revisions.keys.map(\.value)) == [firstID, secondID])
    #expect(state.headRevision == firstID && state[mark: "approved"]?.value == .string(secondID))
    #expect(state.revisions[ExactString(firstID)]?.created == first.clock)
    #expect(state.head.map { $0.clock < first.clock } == true)
  }

  @Test("should leave everything as it was when the extra work throws", arguments: [RemintMode.keepState, .rebuild])
  func shouldRollBackFailingAlso(_ mode: RemintMode) async throws {
    var generator = SeededGenerator(seed: 0xBAD)
    let history = try await makeHistory(&generator, clock: ManualClock())
    let store = history.store
    let before = try await Snapshot(store)
    let error = await #expect(throws: StoreError.self) {
      try await store.remint(to: newReplica(), mode: mode) { db in
        try db.execute(sql: "DELETE FROM projection")
        throw AlsoFailure()
      }
    }
    guard case .aborted(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is AlsoFailure)
    #expect(try await Snapshot(store) == before)
    let next = try await store.write { transaction in try transaction.set(fresh, ["title": "next"]) }
    #expect(next.clock.replica == before.replica)
  }

  @Test("should refuse to re-mint to the current replica")
  func shouldRefuseCurrentReplica() async throws {
    let store = try StoreFixture.open()
    let error = await #expect(throws: StoreError.self) { try await store.remint(to: store.replica, mode: .keepState) }
    #expect(error?.code == "store.replica_reused")
  }

  @Test("should persist the new replica and sequence across reopening")
  func shouldPersistRemint() async throws {
    let directory = TemporaryDirectory()
    let replica = newReplica()
    let pending = try await {
      let store = try StoreFixture.open(at: .file(directory.storeURL))
      _ = try await store.write { transaction in try (1...3).map { try transaction.set(fresh, ["title": .int(Int64($0))]) } }
      try await store.dropChanges(through: 1)
      try await store.remint(to: replica, mode: .keepState)
      return try await store.allPending
    }()
    let reopened = try StoreFixture.open(at: .file(directory.storeURL))
    #expect(reopened.replica == replica)
    #expect(try await reopened.allPending == pending)
    let next = try await reopened.write { transaction in try transaction.set(fresh, ["title": "next"]) }
    #expect(try await reopened.allPending.last == LoggedChange(sequence: 3, line: next.canonicalBytes()))
  }

  @Test("should keep the user's later edit above a remote value from a clock ahead of the device after rebuilding")
  func shouldRebuildAboveObservedClocks() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(clock: clock)
    let ref = EntityRef(kind: Fixture.note, key: Fixture.key("n1"))
    let ahead = must(HLCTimestamp(wallMillis: clock.millis + 3_600_000, counter: 0, replica: Fixture.replicas[1]), "ahead")
    let remote = Fixture.change(.set, ref.kind, ref.key, clock: ahead, fields: ["title": "remote"])
    try await store.apply([remote])
    let local = try await store.write { transaction in try transaction.set(ref, ["title": "local"]) }
    #expect(local.clock > remote.clock)
    try await store.remint(to: newReplica(), mode: .rebuild)
    try await store.apply([remote])
    guard case .record(let state) = try await store.read({ try $0.state(of: ref) }) else { throw StoreTestFailure.unexpectedState }
    #expect(state[field: "title"]?.value == "local")
  }

  @Test("should shed the store's own clock that ran ahead while staying above every observed clock")
  func shouldShedOwnClockAboveObserved() async throws {
    let clock = ManualClock(ManualClock.start.addingTimeInterval(aYear))
    let store = try StoreFixture.open(clock: clock)
    let observed = must(HLCTimestamp(wallMillis: ManualClock(ManualClock.start).millis + 3_600_000, counter: 9, replica: Fixture.replicas[1]), "observed")
    try await store.apply([Fixture.change(.set, Fixture.note, Fixture.key("k3"), clock: observed, fields: ["title": "remote"])])
    let local = try await store.write { transaction in try (1...3).map { try transaction.set(fresh, ["title": .int(Int64($0))]) } }
    clock.set(ManualClock.start)
    try await store.remint(to: newReplica(), mode: .rebuild)
    let rebuilt = try records(try await store.allPending)
    #expect(rebuilt.count == local.count)
    #expect(zip(local, rebuilt).allSatisfy { old, new in new.clock < old.clock && new.clock > observed })
    #expect(zip(rebuilt, rebuilt.dropFirst()).allSatisfy { $0.clock < $1.clock })
    let next = try await store.write { transaction in try transaction.set(fresh, ["title": "next"]) }
    #expect(next.clock > observed && local.allSatisfy { next.clock < $0.clock })
    let stored = try await store.read { transaction in try String.fetchOne(transaction.database, sql: "SELECT observed FROM kernel_state") }
    #expect(stored == observed.description)
  }

  @Test("should persist the highest observed clock, never lowering it, across reopening")
  func shouldPersistObservedClock() async throws {
    let directory = TemporaryDirectory()
    let observed = { (store: VaultStore) in try await store.read { transaction in try String.fetchOne(transaction.database, sql: "SELECT observed FROM kernel_state") } }
    let high = Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(9, replica: 1), fields: ["title": "high"])
    let low = Fixture.change(.set, Fixture.note, Fixture.key("k2"), clock: Fixture.clock(2, replica: 2), fields: ["title": "low"])
    do {
      let store = try StoreFixture.open(at: .file(directory.storeURL))
      #expect(try await observed(store) == nil)
      try await store.apply([high, low])
      _ = try await store.write { transaction in try transaction.set(fresh, ["title": "local"]) }
      #expect(try await observed(store) == high.clock.description)
    }
    let reopened = try StoreFixture.open(at: .file(directory.storeURL))
    #expect(try await observed(reopened) == high.clock.description)
    try await reopened.apply([low])
    #expect(try await observed(reopened) == high.clock.description)
  }
}
