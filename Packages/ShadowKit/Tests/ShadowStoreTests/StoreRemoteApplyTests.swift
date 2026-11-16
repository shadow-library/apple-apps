import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let other = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))

private let ledger = StoreMigration(identifier: "test.segment_ledger") { db in
  try db.execute(sql: "CREATE TABLE segment_ledger (name TEXT NOT NULL)")
}

private struct BodyFailure: Error {}

private func remote(_ ref: EntityRef, _ title: JSONValue, at clock: HLCTimestamp) -> ChangeRecord {
  Fixture.change(.set, ref.kind, ref.key, clock: clock, fields: ["title": title])
}

private func ahead(_ store: ManualClock, by millis: Int64, replica: Int = 1) -> HLCTimestamp {
  must(HLCTimestamp(wallMillis: store.millis + millis, counter: 0, replica: Fixture.replicas[replica]), "ahead")
}

private func ledgerCount(_ store: VaultStore) async throws -> Int {
  try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM segment_ledger") ?? -1 }
}

private func seeded(_ clock: ManualClock = ManualClock(), reconciler: RecordingReconciler? = nil) async throws -> VaultStore {
  let store = try VaultStore.open(.inMemory, registry: Fixture.v2, migrations: [ledger], wallClock: clock.function, reconciler: reconciler)
  _ = try await store.write { transaction in try transaction.set(note, ["title": "local"]) }
  _ = try await store.applyRemote([remote(other, "remote", at: Fixture.clock(1, replica: 1)).canonicalBytes()])
  return store
}

@Suite("VaultStore remote apply")
struct StoreRemoteApplyTests {
  @Test("should equal the retained reference for records in any order with duplicates and unparseable lines, and report what it applied")
  func shouldMatchReference() async throws {
    try await forAll(iterations: 300, seed: 0x2E_3073) { generator in
      let registry = generator.chance(0.5) ? Fixture.v1 : Fixture.v2
      var factory = ChangeFactory()
      let records = factory.changes(&generator, count: 0...30)
      let opaque = (0..<generator.int(in: 0...3)).map { _ in generator.opaqueLine() } + (generator.chance(0.3) ? [Data(" {}".utf8)] : [])
      let lines = Remote.lines(records, opaque: opaque, &generator)
      let store = try StoreFixture.open(registry)
      let parts = generator.int(in: 1...3)
      var results = [RemoteApplyResult]()
      for part in 0..<parts { results.append(try await store.applyRemote(lines.enumerated().filter { $0.offset % parts == part }.map(\.element))) }
      let expected = Remote.reference(records, opaque: opaque, registry)
      try #require(try await store.loadState(.vault) == expected)
      try #require(try await store.loadState(.vault).digest == expected.digest)
      try #require(try await store.loadState(.own).isEmpty)
      try #require(try await store.allPending.isEmpty)
      let recordLines = Set(records.map { $0.canonicalBytes() })
      let opaqueCount = lines.filter { !recordLines.contains($0) }.count
      let applied: Int = results.reduce(0) { $0 + $1.applied }
      let kept: Int = results.reduce(0) { $0 + $1.opaque }
      try #require(applied == lines.count - opaqueCount)
      try #require(kept == opaqueCount)
      try #require(Set(results.flatMap(\.touched)) == Set(Remote.touched(records, registry)))
      try #require(results.allSatisfy { $0.touched == Set($0.touched).sorted() })
      try #require(results.compactMap(\.highestClock).max() == records.map(\.clock).max())
    }
  }

  @Test("should report the touched refs sorted and de-duplicated, the counts and the highest clock")
  func shouldReportResult() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let records = [
      remote(other, "b", at: Fixture.clock(3, replica: 2)), remote(note, "a", at: Fixture.clock(2, replica: 1)), remote(other, "c", at: Fixture.clock(1, replica: 1)),
      Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(9, replica: 1), fields: ["label": "foreign"]),
    ]
    let notCanonical = Data(String(decoding: records[0].canonicalBytes(), as: UTF8.self).replacingOccurrences(of: ",", with: ", ").utf8)
    let result = try await store.applyRemote(records.map { $0.canonicalBytes() } + [records[1].canonicalBytes(), notCanonical, Data()])
    #expect(result == RemoteApplyResult(touched: [note, other], applied: 5, opaque: 2, highestClock: Fixture.clock(9, replica: 1)))
    #expect(try await store.loadState(.vault).opaqueLines == [Data(), notCanonical])
  }

  @Test("should run the extra work in the transaction and return an empty result for no lines")
  func shouldRunBodyForNoLines() async throws {
    let reconciler = RecordingReconciler()
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [ledger], reconciler: reconciler)
    let result = try await store.applyRemote([]) { db in
      guard db.isInsideTransaction else { throw BodyFailure() }
      try db.execute(sql: "INSERT INTO segment_ledger (name) VALUES ('empty')")
    }
    #expect(result == RemoteApplyResult(touched: [], applied: 0, opaque: 0, highestClock: nil))
    #expect(try await ledgerCount(store) == 1)
    #expect(reconciler.calls.isEmpty)
  }

  @Test("should raise observed to the highest remote clock and write locally above it, without touching the own scope or the log")
  func shouldObserveRemoteClocks() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(Fixture.v1, clock: clock)
    let high = ahead(clock, by: 3_600_000, replica: 2)
    _ = try await store.applyRemote([remote(note, "high", at: high), remote(other, "low", at: Fixture.clock(1, replica: 1))].map { $0.canonicalBytes() })
    #expect(try await store.read { try String.fetchOne($0.database, sql: "SELECT observed FROM kernel_state") } == high.description)
    #expect(try await store.loadState(.own).isEmpty)
    #expect(try await store.allPending.isEmpty)
    let local = try await store.write { transaction in try transaction.set(note, ["title": "local"]) }
    #expect(local.clock > high)
  }

  @Test("should accept a clock at the limit and refuse every line when one is above it, naming the highest")
  func shouldGuardTheLimit() async throws {
    let clock = ManualClock()
    let reconciler = RecordingReconciler()
    let store = try await seeded(clock, reconciler: reconciler)
    reconciler.clear()
    let limit = ahead(clock, by: 86_400_000)
    let atLimit = remote(note, "at", at: limit)
    let above = [ahead(clock, by: 86_400_001), ahead(clock, by: 90_000_000, replica: 2)].map { remote(other, "above", at: $0) }
    let before = try await StoreImage(store)
    let error = await #expect(throws: StoreError.self) {
      try await store.applyRemote(([atLimit] + above).map { $0.canonicalBytes() } + [Data("opaque".utf8)], notAfter: limit) { db in
        try db.execute(sql: "INSERT INTO segment_ledger (name) VALUES ('held')")
      }
    }
    guard case .clockAhead(let highest) = error else { throw StoreTestFailure.unexpectedState }
    #expect(highest == above[1].clock)
    #expect(error?.code == "store.clock_ahead")
    #expect(reconciler.calls.isEmpty)
    #expect(try await StoreImage(store) == before)
    #expect(try await ledgerCount(store) == 0)
    let local = try await store.write { transaction in try transaction.set(note, ["title": "after"]) }
    #expect(local.clock < limit)
    #expect(try await store.applyRemote([atLimit.canonicalBytes()], notAfter: limit).applied == 1)
  }

  @Test("should refuse every line when one carries the store's current replica id, but accept a previous one")
  func shouldTripOnCurrentReplica() async throws {
    let reconciler = RecordingReconciler()
    let store = try await seeded(reconciler: reconciler)
    reconciler.clear()
    let previous = store.replica
    let own = Fixture.change(.set, note.kind, note.key, clock: must(HLCTimestamp(wallMillis: 1, counter: 0, replica: previous), "own"), fields: ["title": "twin"])
    let before = try await StoreImage(store)
    let error = await #expect(throws: StoreError.self) {
      try await store.applyRemote([remote(other, "fine", at: Fixture.clock(5, replica: 2)), own].map { $0.canonicalBytes() })
    }
    guard case .replicaCollision(let replica) = error else { throw StoreTestFailure.unexpectedState }
    #expect(replica == previous)
    #expect(error?.code == "store.replica_collision")
    #expect(reconciler.calls.isEmpty)
    #expect(try await StoreImage(store) == before)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .keepState)
    #expect(try await store.applyRemote([own.canonicalBytes()]).touched == [note])
  }

  @Test("should keep nothing, not even the remote clock in memory, when the extra work throws")
  func shouldRollBackFailingBody() async throws {
    let clock = ManualClock()
    let store = try await seeded(clock)
    let before = try await StoreImage(store)
    let high = ahead(clock, by: 3_600_000)
    let error = await #expect(throws: StoreError.self) {
      try await store.applyRemote([remote(note, "lost", at: high).canonicalBytes(), Data("opaque".utf8)]) { db in
        try db.execute(sql: "INSERT INTO segment_ledger (name) VALUES ('lost')")
        throw BodyFailure()
      }
    }
    guard case .aborted(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is BodyFailure)
    #expect(try await StoreImage(store) == before)
    #expect(try await ledgerCount(store) == 0)
    let local = try await store.write { transaction in try transaction.set(other, ["title": "after"]) }
    #expect(local.clock < high)
  }

  @Test("should keep nothing when the reconciler throws")
  func shouldRollBackFailingReconciler() async throws {
    let reconciler = RecordingReconciler()
    let store = try await seeded(reconciler: reconciler)
    let before = try await StoreImage(store)
    reconciler.fail(true)
    let error = await #expect(throws: StoreError.self) {
      try await store.applyRemote([remote(note, "lost", at: Fixture.clock(50, replica: 2)).canonicalBytes()]) { db in
        try db.execute(sql: "INSERT INTO segment_ledger (name) VALUES ('lost')")
      }
    }
    guard case .reconcilerFailed(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is ReconcilerFailure)
    #expect(error?.code == "store.reconciler_failed")
    #expect(try await StoreImage(store) == before)
    #expect(try await ledgerCount(store) == 0)
  }

  @Test("should expose stable codes for the remote, upgrade and reconciler errors")
  func shouldExposeStableCodes() {
    let cases: [(StoreError, String)] = [
      (.clockAhead(Fixture.clock(1)), "store.clock_ahead"), (.replicaCollision(Fixture.replicas[0]), "store.replica_collision"),
      (.incompatibleRegistry("reason"), "store.incompatible_registry"), (.reconcilerFailed(ReconcilerFailure()), "store.reconciler_failed"),
    ]
    for (error, code) in cases { #expect(error.code == code) }
  }
}
