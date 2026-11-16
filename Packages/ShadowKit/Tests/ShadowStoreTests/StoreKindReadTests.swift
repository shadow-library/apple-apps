import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let kinds = [Fixture.note, Fixture.message, Fixture.draft, Fixture.outline, Fixture.tag]

private struct KindRead: Equatable {
  let refs: [EntityRef]
  let states: [EntityState]

  init(_ entries: [(ref: EntityRef, state: EntityState)]) {
    refs = entries.map(\.ref)
    states = entries.map(\.state)
  }

  init(_ state: VaultState, kind: EntityKind) {
    refs = state.refs.filter { $0.kind == kind }
    states = refs.compactMap { state.state(of: $0) }
  }
}

@Suite("VaultStore reads by kind")
struct StoreKindReadTests {
  @Test("should equal the per-entity read and the reference model for every kind in both scopes and both transaction types")
  func shouldMatchReference() async throws {
    try await forAll(iterations: 100, seed: 0x6B_1D) { generator in
      let store = try StoreFixture.open(Fixture.v2)
      var factory = ChangeFactory()
      let remote = factory.changes(&generator, count: 0...30)
      _ = try await store.applyRemote(Remote.lines(remote, &generator))
      let local = try await runLocal((0..<generator.int(in: 0...10)).map { _ in LocalOperation.random(&generator) }, in: store, known: [:]).records
      let expected: [StateScope: VaultState] = [.vault: Remote.reference(local + remote, Fixture.v2), .own: Remote.reference(local, Fixture.v2)]
      for scope in StateScope.allCases {
        let (read, single) = try await store.read { transaction in
          (try kinds.map { KindRead(try transaction.states(ofKind: $0, scope: scope)) }, try kinds.map { kind in try transaction.states(ofKind: kind, scope: scope).map(\.ref) })
        }
        let perEntity = try await store.read { transaction in
          try single.map { refs in try refs.map { try transaction.state(of: $0, scope: scope) } }
        }
        let written = try await store.write { transaction in try kinds.map { KindRead(try transaction.states(ofKind: $0, scope: scope)) } }
        let reference = try #require(expected[scope])
        try #require(read == kinds.map { KindRead(reference, kind: $0) })
        try #require(written == read)
        try #require(perEntity == read.map { $0.states.map(Optional.some) })
      }
    }
  }

  @Test("should list purged entities and order the entities by key bytes")
  func shouldIncludePurgedInKeyOrder() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let keys = ["b", "a1", "a", "a-", "a_"].map(Fixture.key)
    _ = try await store.write { transaction in
      for key in keys { _ = try transaction.set(EntityRef(kind: Fixture.note, key: key), ["title": .string(key.rawValue)]) }
      _ = try transaction.purge(EntityRef(kind: Fixture.note, key: keys[0]))
    }
    let states = try await store.read { transaction in try transaction.states(ofKind: Fixture.note) }
    #expect(states.map(\.ref.key.rawValue) == ["a", "a-", "a1", "a_", "b"])
    guard case .purged = states.last?.state else { throw StoreTestFailure.unexpectedState }
  }

  @Test("should return nothing for an undeclared kind, even with foreign records of it")
  func shouldIgnoreUndeclaredKind() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.applyRemote([Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1, replica: 1), fields: ["label": "x"]).canonicalBytes()])
    #expect(try await store.read { transaction in try transaction.states(ofKind: Fixture.tag) }.isEmpty)
    #expect(try await store.loadState(.vault).foreign.count == 1)
  }

  @Test("should read thousands of entities of one kind without reading another kind's rows")
  func shouldScanOnlyTheKind() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let notes = (0..<3_000).map { Fixture.change(.set, Fixture.note, Fixture.key("n\($0)"), clock: Fixture.clock(1, replica: 1), fields: ["title": .int(Int64($0))]) }
    _ = try await store.applyRemote(notes.map { $0.canonicalBytes() })
    _ = try await store.write { transaction in try transaction.append(EntityRef(kind: Fixture.message, key: Fixture.key("m1")), item: ["text": "x"]) }
    try await store.write { transaction in try transaction.database.execute(sql: "UPDATE appended_item SET item = CAST('not json' AS BLOB)") }
    let states = try await store.read { transaction in try transaction.states(ofKind: Fixture.note) }
    #expect(states.count == 3_000)
    #expect(states.map(\.ref) == notes.map(\.ref).sorted())
    let error = await #expect(throws: StoreError.self) { try await store.read { transaction in try transaction.states(ofKind: Fixture.message) } }
    #expect(error?.code == "store.corrupt_store")
  }
}
