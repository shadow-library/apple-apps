import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

private let ledger = StoreMigration(identifier: "test.drop_ledger") { db in
  try db.execute(sql: "CREATE TABLE drop_ledger (pending INTEGER NOT NULL)")
}

private struct DropRefused: Error {}

private func writeNotes(_ count: Int, to store: VaultStore) async throws {
  _ = try await store.write { transaction in
    for index in 0..<count { _ = try transaction.set(note, ["title": .string("title \(index)")]) }
  }
}

@Suite("VaultStore drop with a caller's step")
struct StoreDropChangesTests {
  @Test("should run the caller's step in the drop's transaction, before the rows go")
  func shouldRunStepInsideDrop() async throws {
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [ledger], wallClock: ManualClock().function)
    try await writeNotes(3, to: store)

    try await store.dropChanges(through: 2) { db in
      try db.execute(sql: "INSERT INTO drop_ledger (pending) SELECT COUNT(*) FROM change_log")
    }

    #expect(try await store.allPending.map(\.sequence) == [3])
    #expect(try await store.read { try Int.fetchAll($0.database, sql: "SELECT pending FROM drop_ledger") } == [3])
  }

  @Test("should drop nothing and acknowledge nothing when the caller's step throws")
  func shouldRollBackWhenStepThrows() async throws {
    let store = try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: [ledger], wallClock: ManualClock().function)
    try await writeNotes(2, to: store)
    let before = try await store.allPending

    await #expect(throws: StoreError.self) {
      try await store.dropChanges(through: 2) { db in
        try db.execute(sql: "INSERT INTO drop_ledger (pending) VALUES (0)")
        throw DropRefused()
      }
    }

    #expect(try await store.allPending == before)
    #expect(try await store.publicClockFloor() == nil)
    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM drop_ledger") } == 0)
  }
}
