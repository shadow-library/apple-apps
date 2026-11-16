import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Synchronization
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let other = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))

private let ledger = StoreMigration(identifier: "test.adopt_ledger") { db in
  try db.execute(sql: "CREATE TABLE adopt_ledger (name TEXT NOT NULL)")
}

private struct BodyFailure: Error {}

private func remote(_ ref: EntityRef, _ title: JSONValue, at clock: HLCTimestamp) -> ChangeRecord {
  Fixture.change(.set, ref.kind, ref.key, clock: clock, fields: ["title": title])
}

private func records(_ lines: [Data]) throws -> [ChangeRecord] {
  try lines.map { try Stored.record($0) }
}

private func foreignBytes(_ state: VaultState) -> [Data] {
  state.foreign.map { $0.canonicalBytes() }.sorted { $0.lexicographicallyPrecedes($1) }
}

private func opaqueBytes(_ state: VaultState) -> [Data] {
  state.opaqueLines.sorted { $0.lexicographicallyPrecedes($1) }
}

private struct Adopted {
  let store: VaultStore
  let model: VaultState
  var undeclaredKind = false
  var undeclaredField = false
  var opaque = false
}

private struct Observation: Sendable, Equatable {
  let vaultRevisions: Int
  let ownRevisions: Int
  let reconcilerCalls: Int
}

private func adoptRandomly(_ generator: inout SeededGenerator, registry: SchemaRegistry = Fixture.v1) async throws -> Adopted {
  let store = try StoreFixture.open(registry)
  var factory = ChangeFactory()
  var known = [EntityRef: [String]]()
  var model = VaultState()
  var result = Adopted(store: store, model: model)
  for _ in 0..<generator.int(in: 1...6) {
    if generator.chance(0.35) {
      let result = try await runLocalLeniently((0..<generator.int(in: 1...6)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
      known = result.known
      for record in result.records { model.apply(record, registry: registry) }
    } else {
      var adopted = factory.changes(&generator, count: 0...15)
      if generator.chance(0.4) {
        adopted.append(Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: factory.clock(&generator), fields: ["label": "x"], id: Fixture.uuid(&generator)))
      }
      if generator.chance(0.4) {
        adopted.append(
          Fixture.change(
            .set, Fixture.note, generator.pick(from: Fixture.noteKeys), clock: factory.clock(&generator), fields: ["title": "t", "pinned": true], id: Fixture.uuid(&generator)))
      }
      let opaque = (0..<generator.int(in: 0...2)).map { _ in generator.opaqueLine() }
      result.undeclaredKind = result.undeclaredKind || adopted.contains { registry[$0.entity] == nil }
      result.undeclaredField = result.undeclaredField || adopted.contains { registry[$0.entity] != nil && registry.interpretation(of: $0).foreign != nil && $0.kind == .set }
      result.opaque = result.opaque || !opaque.isEmpty
      _ = try await store.adoptRemote(Remote.lines(adopted, opaque: opaque, &generator))
      for record in adopted { model.apply(record, registry: registry) }
      for line in opaque { model.keepOpaque(line) }
    }
  }
  return Adopted(store: store, model: model.retained(registry: registry), undeclaredKind: result.undeclaredKind, undeclaredField: result.undeclaredField, opaque: result.opaque)
}

@Suite("VaultStore adoption")
struct StoreAdoptTests {
  @Test("should give the same vault scope, result and reconciler calls as applyRemote")
  func shouldMatchApplyRemoteInTheVaultScope() async throws {
    try await forAll(iterations: 100, seed: 0xAD_0001) { generator in
      let registry = generator.chance(0.5) ? Fixture.v1 : Fixture.v2
      var factory = ChangeFactory()
      let records = factory.changes(&generator, count: 0...25)
      let lines = Remote.lines(records, opaque: [generator.opaqueLine()], &generator)
      let appliedReconciler = RecordingReconciler()
      let adoptedReconciler = RecordingReconciler()
      let applied = try VaultStore.open(.inMemory, registry: registry, reconciler: appliedReconciler)
      let adopted = try VaultStore.open(.inMemory, registry: registry, reconciler: adoptedReconciler)
      let first = try await applied.applyRemote(lines)
      let second = try await adopted.adoptRemote(lines)
      try #require(first == second)
      try #require(try await applied.loadState(.vault).digest == adopted.loadState(.vault).digest)
      try #require(try await applied.loadState(.vault) == adopted.loadState(.vault))
      try #require(appliedReconciler.calls == adoptedReconciler.calls)
      try #require(adoptedReconciler.calls.count == (first.touched.isEmpty ? 0 : 1))
    }
  }

  @Test("should carry every adopted record, foreign record and opaque line into the own scope as the model does")
  func shouldMergeIntoTheOwnScope() async throws {
    let iterations = 150
    var kinds = 0
    var fields = 0
    var opaques = 0
    try await forAll(iterations: iterations, seed: 0xAD_0002) { generator in
      let result = try await adoptRandomly(&generator)
      kinds += result.undeclaredKind ? 1 : 0
      fields += result.undeclaredField ? 1 : 0
      opaques += result.opaque ? 1 : 0
      let own = try await result.store.loadState(.own)
      try #require(own.digest == result.model.digest)
      try #require(own == result.model)
      try #require(foreignBytes(own) == foreignBytes(result.model))
      try #require(opaqueBytes(own) == opaqueBytes(result.model))
    }
    #expect(kinds >= iterations / 4)
    #expect(fields >= iterations / 4)
    #expect(opaques >= iterations / 4)
  }

  @Test("should emit adopted content in the base so a fresh store replays to the model, byte for byte")
  func shouldCarryAdoptedContentInTheBase() async throws {
    try await forAll(iterations: 100, seed: 0xAD_0003) { generator in
      let result = try await adoptRandomly(&generator)
      let snapshot = try await result.store.ownSnapshot()
      let fresh = try StoreFixture.open(Fixture.v1)
      _ = try await fresh.applyRemote(snapshot.lines)
      let replayed = try await fresh.loadState(.vault)
      try #require(replayed.digest == result.model.digest)
      try #require(foreignBytes(replayed) == foreignBytes(result.model))
      try #require(opaqueBytes(replayed) == opaqueBytes(result.model))
    }
  }

  @Test("should keep an unknown field, an undeclared kind and an opaque line in the base verbatim")
  func shouldKeepUnknownContentInTheBase() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let unknownField = Fixture.change(.set, Fixture.note, note.key, clock: Fixture.clock(2, replica: 1), fields: ["title": "t", "pinned": true])
    let unknownKind = Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(3, replica: 1), fields: ["label": "x"])
    let opaque = Data("not json".utf8)
    _ = try await store.adoptRemote([unknownField, unknownKind].map { $0.canonicalBytes() } + [opaque])
    let lines = try await store.ownSnapshot().lines
    let decoded = try records(lines.filter { $0 != opaque })
    #expect(lines.contains(opaque))
    #expect(decoded.contains { $0.entity == Fixture.tag && $0.fields["label"] == "x" })
    #expect(decoded.contains { $0.entity == Fixture.note && $0.fields["pinned"] == true })
  }

  @Test("should prune the own scope to the retention limit exactly as the model does")
  func shouldRetainInTheOwnScope() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let revisions = (0..<6).map { index in
      let clock = Fixture.clock(Int64(index), replica: 1)
      return Fixture.revise(RevisionItem(parent: nil, body: .int(Int64(index)), created: clock, generation: Int64(index)), clock: clock, key: draft.key)
    }
    let unpruned = Fixture.state(revisions, Fixture.v1)
    let expected = unpruned.retained(registry: Fixture.v1)
    try #require(expected.digest != unpruned.digest)
    _ = try await store.adoptRemote(revisions.map { $0.canonicalBytes() })
    #expect(try await store.loadState(.own).digest == expected.digest)
    #expect(try await store.loadState(.vault).digest == expected.digest)
  }

  @Test("should remove an entity this store wrote from the own scope when a purge is adopted, and emit the purge in the base")
  func shouldApplyAdoptedPurgeToOwnWrites() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    let purge = Fixture.change(.purge, note.kind, note.key, clock: Fixture.clock(5, replica: 1))
    _ = try await store.adoptRemote([purge.canonicalBytes()])
    guard case .purged? = try await store.read({ try $0.state(of: note, scope: .own) }) else { throw StoreTestFailure.unexpectedState }
    let emitted = try records(try await store.ownSnapshot().lines)
    #expect(emitted.contains { $0.kind == .purge && $0.ref == note })
    #expect(!emitted.contains { $0.kind == .set && $0.ref == note })
  }

  @Test("should refuse a clock past the limit before changing either scope, the change log or the observed clock")
  func shouldGuardTheLimit() async throws {
    let clock = ManualClock()
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [ledger], wallClock: clock.function)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    _ = try await store.adoptRemote([remote(other, "seed", at: Fixture.clock(1, replica: 1)).canonicalBytes()])
    let before = try await StoreImage(store)
    let limit = must(HLCTimestamp(wallMillis: clock.millis + 1_000, counter: 0, replica: Fixture.replicas[1]), "limit")
    let above = must(HLCTimestamp(wallMillis: clock.millis + 2_000, counter: 0, replica: Fixture.replicas[2]), "above")
    let error = await #expect(throws: StoreError.self) {
      try await store.adoptRemote([remote(note, "late", at: above), remote(other, "fine", at: limit)].map { $0.canonicalBytes() } + [Data("opaque".utf8)], notAfter: limit) { db in
        try db.execute(sql: "INSERT INTO adopt_ledger (name) VALUES ('held')")
      }
    }
    guard case .clockAhead(let highest) = error else { throw StoreTestFailure.unexpectedState }
    #expect(highest == above)
    #expect(try await StoreImage(store) == before)
    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM adopt_ledger") } == 0)
  }

  @Test("should refuse a record carrying the store's replica before changing either scope, ahead of the clock check")
  func shouldGuardTheReplica() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    let before = try await StoreImage(store)
    let twin = remote(note, "twin", at: must(HLCTimestamp(wallMillis: 1, counter: 0, replica: store.replica), "twin"))
    let above = remote(other, "above", at: Fixture.clock(9, replica: 1))
    let limit = Fixture.clock(1, replica: 1)
    let error = await #expect(throws: StoreError.self) { try await store.adoptRemote([above, twin].map { $0.canonicalBytes() }, notAfter: limit) }
    guard case .replicaCollision(let replica) = error else { throw StoreTestFailure.unexpectedState }
    #expect(replica == store.replica)
    #expect(try await StoreImage(store) == before)
  }

  @Test("should roll back both scopes and the settled state when the extra work throws, and run it in the same transaction")
  func shouldRollBackWhenTheExtraWorkThrows() async throws {
    let reconciler = RecordingReconciler()
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [ledger], reconciler: reconciler)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    let before = try await StoreImage(store)
    let error = await #expect(throws: StoreError.self) {
      try await store.adoptRemote([remote(other, "x", at: Fixture.clock(2, replica: 1)).canonicalBytes(), Data("opaque".utf8)]) { db in
        try db.execute(sql: "INSERT INTO adopt_ledger (name) VALUES ('held')")
        throw BodyFailure()
      }
    }
    guard case .aborted(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is BodyFailure)
    #expect(try await StoreImage(store) == before)
    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM adopt_ledger") } == 0)
    let inside = try await store.adoptRemote([remote(other, "y", at: Fixture.clock(3, replica: 1)).canonicalBytes()]) { db in
      guard db.isInsideTransaction else { throw BodyFailure() }
      try db.execute(sql: "INSERT INTO adopt_ledger (name) VALUES ('kept')")
    }
    #expect(inside.touched == [other])
    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM adopt_ledger") } == 1)
  }

  @Test("should run the extra work after pruning and reconciling, seeing settled state", arguments: [true, false])
  func shouldRunTheExtraWorkLast(_ adopting: Bool) async throws {
    let reconciler = RecordingReconciler()
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, reconciler: reconciler)
    let revisions = (0..<6).map { index in
      let clock = Fixture.clock(Int64(index), replica: 1)
      return Fixture.revise(RevisionItem(parent: nil, body: .int(Int64(index)), created: clock, generation: Int64(index)), clock: clock, key: draft.key)
    }
    let lines = revisions.map { $0.canonicalBytes() }
    let observed = Mutex<Observation?>(nil)
    let body: @Sendable (Database) throws -> Void = { db in
      let count: (StateScope) throws -> Int = { scope in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM revision WHERE scope = ?", arguments: [scope.rawValue]) ?? -1 }
      let vault = try count(.vault)
      let own = try count(.own)
      observed.withLock { $0 = Observation(vaultRevisions: vault, ownRevisions: own, reconcilerCalls: reconciler.calls.count) }
    }
    if adopting { _ = try await store.adoptRemote(lines, also: body) } else { _ = try await store.applyRemote(lines, also: body) }
    #expect(observed.withLock { $0 } == Observation(vaultRevisions: 3, ownRevisions: adopting ? 3 : 0, reconcilerCalls: 1))
  }

  @Test("should log nothing, leaving pending changes, the next sequence and the base position unchanged")
  func shouldLogNothing() async throws {
    try await forAll(iterations: 50, seed: 0xAD_0004) { generator in
      let store = try StoreFixture.open(Fixture.v1)
      var factory = ChangeFactory()
      _ = try await runLocalLeniently((0..<generator.int(in: 1...6)).map { _ in LocalOperation.random(&generator) }, in: store, known: [:])
      let pending = try await store.allPending
      let sequence = try await store.write { try $0.nextSequence }
      let upTo = try await store.ownSnapshot().upTo
      _ = try await store.adoptRemote(Remote.lines(factory.changes(&generator, count: 0...15), &generator))
      try #require(try await store.allPending == pending)
      try #require(try await store.write { try $0.nextSequence } == sequence)
      try #require(try await store.ownSnapshot().upTo == upTo)
      try #require(upTo == sequence - 1)
    }
  }

  @Test("should change nothing the second time the same lines are adopted")
  func shouldBeIdempotent() async throws {
    try await forAll(iterations: 50, seed: 0xAD_0005) { generator in
      let store = try StoreFixture.open(Fixture.v1)
      var factory = ChangeFactory()
      _ = try await runLocalLeniently((0..<generator.int(in: 0...5)).map { _ in LocalOperation.random(&generator) }, in: store, known: [:])
      let lines = Remote.lines(factory.changes(&generator, count: 0...15), opaque: [generator.opaqueLine()], &generator)
      _ = try await store.adoptRemote(lines)
      let image = try await StoreImage(store)
      let snapshot = try await store.ownSnapshot()
      _ = try await store.adoptRemote(lines)
      try #require(try await StoreImage(store) == image)
      try #require(try await store.ownSnapshot() == snapshot)
    }
  }

  @Test("should leave only the re-logged unsent changes in the own scope and keep everything in the vault scope after remint keepState")
  func shouldDropAdoptedContentFromTheOwnScopeWhenKeepingState() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let local = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    _ = try await store.adoptRemote([remote(other, "theirs", at: Fixture.clock(2, replica: 1)).canonicalBytes(), Data("opaque".utf8)])
    let vault = try await store.loadState(.vault)
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .keepState)
    #expect(try await store.loadState(.own).digest == Fixture.state([local], Fixture.v1).digest)
    #expect(try await store.loadState(.own).opaqueLines.isEmpty)
    #expect(try await store.loadState(.vault) == vault)
    #expect(try await store.read { try $0.state(of: other) } != nil)
    #expect(try await store.read { try $0.state(of: other, scope: .own) } == nil)
  }

  @Test("should hold the adopted content in neither scope after remint rebuild")
  func shouldDropAdoptedContentFromBothScopesWhenRebuilding() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "mine"]) }
    _ = try await store.adoptRemote([remote(other, "theirs", at: Fixture.clock(2, replica: 1)).canonicalBytes(), Data("opaque".utf8)])
    try await store.remint(to: ReplicaID(UUID.v7()), mode: .rebuild)
    let relogged = try records(try await store.allPending.map(\.line))
    let expected = Fixture.state(relogged, Fixture.v1).digest
    #expect(try await store.loadState(.own).digest == expected)
    #expect(try await store.loadState(.vault).digest == expected)
    #expect(try await store.read { try $0.state(of: other) } == nil)
    #expect(try await store.loadState(.vault).opaqueLines.isEmpty)
  }
}
