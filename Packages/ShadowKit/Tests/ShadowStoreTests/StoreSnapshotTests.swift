import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

private func replayed(_ lines: [Data], _ registry: SchemaRegistry) -> VaultState {
  var state = VaultState()
  for line in lines {
    if let json = try? CanonicalJSON.decode(line), let record = try? ChangeRecord(json: json) {
      state.apply(record, registry: registry)
    } else {
      state.keepOpaque(line)
    }
  }
  return state
}

@Suite("VaultStore own snapshot")
struct StoreSnapshotTests {
  @Test("should replay to the own scope and stay byte-identical until the next write")
  func shouldReplayToOwnScope() async throws {
    try await forAll(iterations: 200, seed: 0x5A_9500) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var factory = ChangeFactory()
      var known = [EntityRef: [String]]()
      var written = 0
      for _ in 0..<generator.int(in: 1...5) {
        if generator.chance(0.4) {
          _ = try await store.applyRemote(Remote.lines(factory.changes(&generator, count: 0...10), &generator))
        } else {
          let result = try await runLocal((0..<generator.int(in: 1...6)).map { _ in LocalOperation.random(&generator) }, in: store, known: known)
          written += result.records.count
          known = result.known
        }
      }
      if generator.chance(0.3) {
        let planted = (0..<generator.int(in: 1...3)).map { _ in factory.foreign(&generator) }
        try await store.apply(planted, scope: .own)
        try await store.keepOpaque([generator.opaqueLine()], scope: .own)
      }
      let snapshot = try await store.ownSnapshot()
      let own = try await store.loadState(.own)
      try #require(replayed(snapshot.lines, Fixture.v2) == own)
      try #require(snapshot.replica == store.replica)
      try #require(snapshot.upTo == Int64(written))
      try #require(snapshot.schema == (own.records(schema: Fixture.v2.version).map(\.schema).max() ?? Fixture.v2.version))
      try #require(try await store.ownSnapshot() == snapshot)
      _ = try await store.applyRemote(Remote.lines(factory.changes(&generator, count: 0...4), &generator))
      try #require(try await store.ownSnapshot() == snapshot)
    }
  }

  @Test("should be empty for a fresh store")
  func shouldBeEmptyWhenFresh() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    #expect(try await store.ownSnapshot() == OwnSnapshot(replica: store.replica, upTo: 0, schema: Fixture.v2.version, lines: []))
  }

  @Test("should hold only the pending changes after re-minting with the state kept")
  func shouldHoldPendingAfterRemint() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    let written = try await store.write { transaction in try (1...4).map { try transaction.set(note, ["title": .int(Int64($0)), "origin": .int(Int64($0))]) } }
    try await store.dropChanges(through: 2)
    let replica = ReplicaID(UUID.v7())
    try await store.remint(to: replica, mode: .keepState)
    let snapshot = try await store.ownSnapshot()
    #expect(snapshot.replica == replica)
    #expect(snapshot.upTo == 2)
    #expect(replayed(snapshot.lines, Fixture.v2) == Fixture.state(Array(written.suffix(2)), Fixture.v2))
    let next = try await store.write { transaction in try transaction.set(note, ["title": "next"]) }
    let after = try await store.ownSnapshot()
    #expect(after.upTo == 3)
    #expect(replayed(after.lines, Fixture.v2) == Fixture.state(Array(written.suffix(2)) + [next], Fixture.v2))
  }
}
