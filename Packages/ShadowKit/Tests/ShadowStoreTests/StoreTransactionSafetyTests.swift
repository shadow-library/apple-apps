import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
private let other = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))

private func expectOnly(_ kept: [ChangeRecord], in store: VaultStore) async throws {
  #expect(try await store.allPending == StoreFixture.logged(kept))
  #expect(try await store.loadState(.vault).digest == Fixture.state(kept).digest)
  #expect(try await store.loadState(.own).digest == Fixture.state(kept).digest)
}

@Suite("VaultStore transaction safety")
struct StoreTransactionSafetyTests {
  @Test("should never reuse a sequence number when two handles write in one transaction")
  func shouldOwnTheSequenceInTheDatabase() async throws {
    let store = try StoreFixture.open()
    let written = try await store.write { transaction in
      var second = WriteTransaction(database: transaction.database, registry: transaction.registry, clock: transaction.clock, ids: transaction.ids)
      return [try second.set(note, ["title": "second handle"]), try transaction.set(other, ["title": "first handle"])]
    }
    #expect(try await store.allPending == StoreFixture.logged(written))
    try await store.dropChanges(through: 1)
    let next = try await store.write { transaction in try transaction.set(other, ["title": "next"]) }
    #expect(try await store.allPending == StoreFixture.logged([written[1], next], from: 2))
  }

  @Test("should keep nothing of a local write whose own-scope step fails after the vault step, even when the body swallows the failure")
  func shouldRollBackFailedOwnStep() async throws {
    let store = try StoreFixture.open()
    let (failed, kept) = try await store.write { transaction in
      try transaction.database.execute(
        sql: "INSERT INTO field_state (scope, kind, key, slot, name, value, clock) VALUES (1, 'note', 'k1', 0, ?, ?, 'not a clock')",
        arguments: [Stored.name("title"), CanonicalJSON.encode("planted")])
      let failed = (try? transaction.set(note, ["title": "lost"])) == nil
      try transaction.database.execute(sql: "DELETE FROM field_state WHERE scope = 1")
      let kept = try transaction.set(other, ["title": "kept"])
      #expect(transaction.changes == [kept])
      return (failed, kept)
    }
    #expect(failed)
    try await expectOnly([kept], in: store)
  }

  @Test("should keep nothing of a local write whose log step fails after both scope steps, even when the body swallows the failure")
  func shouldRollBackFailedLogStep() async throws {
    let store = try StoreFixture.open()
    let (failed, kept) = try await store.write { transaction in
      try transaction.database.execute(sql: "INSERT INTO change_log (seq, line) VALUES (1, x'00')")
      let failed = (try? transaction.set(note, ["title": "lost"])) == nil
      try transaction.database.execute(sql: "DELETE FROM change_log")
      return (failed, try transaction.set(other, ["title": "kept"]))
    }
    #expect(failed)
    try await expectOnly([kept], in: store)
  }

  @Test("should keep nothing of an applied record whose clock bookkeeping fails, even when the body swallows the failure")
  func shouldRollBackFailedApply() async throws {
    let store = try StoreFixture.open()
    let remote = Fixture.change(.set, Fixture.note, note.key, clock: Fixture.clock(1), fields: ["title": "remote", "origin": "remote"])
    let failed = try await store.write { transaction in
      try transaction.database.execute(sql: "CREATE TRIGGER planted BEFORE UPDATE OF observed ON kernel_state BEGIN SELECT RAISE(ABORT, 'planted'); END")
      let failed = (try? transaction.apply(remote)) == nil
      try transaction.database.execute(sql: "DROP TRIGGER planted")
      return failed
    }
    #expect(failed)
    #expect(try await store.loadState(.vault).isEmpty)
  }

  @Test("should refuse a write once the sequence counter is exhausted, without trapping")
  func shouldRefuseExhaustedSequence() async throws {
    let store = try StoreFixture.open()
    try await store.write { transaction in try transaction.database.execute(sql: "UPDATE kernel_state SET next_sequence = ?", arguments: [Int64.max]) }
    let error = await #expect(throws: StoreError.self) { try await store.write { transaction in try transaction.set(note, ["title": "t"]) } }
    #expect(error?.code == "store.sequence_exhausted")
    #expect(try await store.loadState(.vault).isEmpty)
  }
}
