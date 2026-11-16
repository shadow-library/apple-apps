import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private struct Plant: Sendable, CustomTestStringConvertible {
  let name: String
  let sql: String
  let arguments: StatementArguments

  init(_ name: String, _ sql: String, _ arguments: StatementArguments = []) {
    self.name = name
    self.sql = sql
    self.arguments = arguments
  }

  var testDescription: String { name }
}

private let revisionItem = RevisionItem(parent: nil, body: "b", created: Fixture.clock(1), generation: 0)

private let plants: [Plant] = [
  Plant("a revision row whose id is not its item's", "UPDATE revision SET id = 'v:0000'"),
  Plant("a revision row whose item is not canonical", "UPDATE revision SET item = CAST('{ }' AS BLOB)"),
  Plant("a foreign row with the wrong role", "UPDATE foreign_record SET role = 2"),
  Plant("a foreign row under another entity", "UPDATE foreign_record SET key = 'k9'"),
  Plant("a foreign row whose bytes are not canonical", "UPDATE foreign_record SET bytes = CAST(x'20' || bytes AS BLOB)"),
  Plant(
    "a head on a record kind", "INSERT INTO field_state VALUES (0, 'note', 'k1', 1, ?, ?, ?)",
    [Stored.name("head"), CanonicalJSON.encode(.string(revisionItem.id)), Fixture.clock(1).description]),
  Plant(
    "an undeclared mark", "INSERT INTO field_state VALUES (0, 'draft', 'd1', 2, ?, ?, ?)",
    [Stored.name("reviewed"), CanonicalJSON.encode(.string(revisionItem.id)), Fixture.clock(1).description]),
  Plant(
    "a mark naming a revision that is not held", "INSERT INTO field_state VALUES (0, 'draft', 'd1', 2, ?, ?, ?)",
    [Stored.name("approved"), CanonicalJSON.encode("v:missing"), Fixture.clock(1).description]),
  Plant(
    "a value outside the monotone order", "INSERT INTO field_state VALUES (0, 'note', 'k1', 0, ?, ?, ?)",
    [Stored.name("status"), CanonicalJSON.encode("archived"), Fixture.clock(1).description]),
  Plant(
    "an undeclared field", "INSERT INTO field_state VALUES (0, 'note', 'k1', 0, ?, ?, ?)",
    [Stored.name("pinned"), CanonicalJSON.encode(true), Fixture.clock(1).description]),
  Plant("an item on a record kind", "INSERT INTO appended_item VALUES (0, 'note', 'k1', CAST('{}' AS BLOB), ?)", [Fixture.clock(1).description]),
  Plant("a malformed clock", "UPDATE field_state SET clock = 'yesterday' WHERE kind = 'note'"),
  Plant("a value of the wrong storage class", "UPDATE tombstone SET clock = 42"),
  Plant("state beside a tombstone", "INSERT INTO appended_item VALUES (0, 'message', 'm1', CAST('{}' AS BLOB), ?)", [Fixture.clock(1).description]),
  Plant(
    "foreign data beside a tombstone", "INSERT INTO foreign_record VALUES (0, ?, 'message', 'm1', 0)",
    [Fixture.change(.set, Fixture.message, Fixture.key("m1"), clock: Fixture.clock(1), fields: ["text": "x"]).canonicalBytes()]),
]

private func seeded() async throws -> VaultStore {
  let store = try StoreFixture.open(Fixture.v1)
  try await store.apply([
    Fixture.change(.set, Fixture.note, Fixture.key("k1"), clock: Fixture.clock(1), fields: ["title": "t"]),
    Fixture.revise(revisionItem, clock: Fixture.clock(1), head: false),
    Fixture.change(.set, Fixture.tag, Fixture.key("t1"), clock: Fixture.clock(1), fields: ["label": "x"]),
    Fixture.change(.purge, Fixture.message, Fixture.key("m1"), clock: Fixture.clock(1)),
  ])
  return store
}

@Suite("VaultStore stored-row verification")
struct StoreCorruptionTests {
  @Test("should report a planted inconsistent row as a corrupt store instead of trusting it", arguments: plants)
  fileprivate func shouldRejectPlantedRow(_ plant: Plant) async throws {
    let store = try await seeded()
    try await store.write { transaction in try transaction.database.execute(sql: plant.sql, arguments: plant.arguments) }
    let error = await #expect(throws: StoreError.self) { try await store.loadState(.vault) }
    #expect(error?.code == "store.corrupt_store")
  }

  @Test("should report a malformed kernel row as a corrupt store")
  func shouldRejectMalformedKernelRow() async throws {
    let store = try await seeded()
    try await store.write { transaction in try transaction.database.execute(sql: "UPDATE kernel_state SET clock = 'soon'") }
    let ref = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
    let error = await #expect(throws: StoreError.self) { try await store.write { transaction in try transaction.set(ref, ["title": "t"]) } }
    #expect(error?.code == "store.corrupt_store")
  }
}
