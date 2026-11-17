import Foundation
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private func note(_ key: String) -> EntityRef {
  EntityRef(kind: Fixture.note, key: Fixture.key(key))
}

private func titles(_ store: VaultStore) async throws -> [EntityKey: [String: JSONValue]] {
  try await store.read { transaction in try transaction.fieldValues(ofKind: Fixture.note, named: ["title"]) }
}

@Suite("VaultStore field values by kind")
struct StoreFieldValuesTests {
  @Test("should return only the named fields of each entity of the kind")
  func shouldReturnNamedFields() async throws {
    let store = try StoreFixture.open()
    _ = try await store.write { transaction in
      _ = try transaction.set(note("k1"), ["title": "one", "status": "draft"])
      _ = try transaction.set(note("k2"), ["status": "draft"])
    }
    let read = try await store.read { transaction in try transaction.fieldValues(ofKind: Fixture.note, named: ["title", "origin"]) }
    #expect(read == [Fixture.key("k1"): ["title": "one"]])
  }

  @Test("should leave out a purged entity")
  func shouldSkipPurged() async throws {
    let store = try StoreFixture.open()
    _ = try await store.write { transaction in
      _ = try transaction.set(note("k1"), ["title": "kept"])
      _ = try transaction.set(note("k2"), ["title": "gone"])
      _ = try transaction.purge(note("k2"))
    }
    #expect(try await titles(store) == [Fixture.key("k1"): ["title": "kept"]])
  }

  @Test("should return the merged value, not a superseded one, and read the vault scope rather than the replica's own")
  func shouldReturnMergedVaultValue() async throws {
    let store = try StoreFixture.open()
    _ = try await store.write { transaction in try transaction.set(note("k1"), ["title": "local"]) }
    let remote = Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(10_000, replica: 1), fields: ["title": "remote"])
    _ = try await store.applyRemote([remote.canonicalBytes()])
    let own = try await store.read { transaction in try transaction.state(of: note("k1"), scope: .own) }
    guard case .record(let ownRecord)? = own else { throw StoreTestFailure.unexpectedState }
    try #require(ownRecord[field: "title"]?.value == "local")
    #expect(try await titles(store) == [Fixture.key("k1"): ["title": "remote"]])
  }

  @Test("should leave out foreign fields held aside, and refuse a field the kind does not declare")
  func shouldSkipForeignFields() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    let changes = [
      Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1, replica: 1), schema: 9, fields: ["title": "known", "pinned": true]),
      Fixture.change(.set, Fixture.note, Fixture.key("k2"), clock: Fixture.clock(1, replica: 1), schema: 9, fields: ["pinned": true]),
    ]
    _ = try await store.applyRemote(changes.map { $0.canonicalBytes() })
    try #require(try await store.loadState(.vault).foreign.isEmpty == false)
    #expect(try await titles(store) == [Fixture.key("k1"): ["title": "known"]])
    await #expect(throws: StoreError.self) {
      try await store.read { transaction in try transaction.fieldValues(ofKind: Fixture.note, named: ["title", "pinned"]) }
    }
  }

  @Test("should return nothing for an undeclared kind, even with foreign records of it")
  func shouldIgnoreUndeclaredKind() async throws {
    let store = try StoreFixture.open(Fixture.v1)
    _ = try await store.applyRemote([Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1, replica: 1), fields: ["label": "x"]).canonicalBytes()])
    #expect(try await store.read { transaction in try transaction.fieldValues(ofKind: Fixture.tag, named: ["label"]) }.isEmpty)
    #expect(try await store.loadState(.vault).foreign.count == 1)
  }
}
