import Foundation
import GRDB
import ShadowCore
import Testing

@testable import ShadowStore

private struct Underlying: Error {}

@Suite("StoreError")
struct StoreErrorTests {
  @Test("should expose a stable code for every case")
  func shouldExposeStableCodes() throws {
    let ref = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
    let replica = try #require(ReplicaID("00000000-0000-0000-0000-00000000000a"))
    let cases: [(StoreError, String)] = [
      (.database("disk full"), "store.database"), (.invalidChange("reason"), "store.invalid_change"), (.changeTooLarge(5), "store.change_too_large"),
      (.unknownRevision("v:00"), "store.unknown_revision"), (.entityPurged(ref), "store.entity_purged"), (.duplicateMigration("a"), "store.duplicate_migration"),
      (.corruptStore("reason"), "store.corrupt_store"), (.replicaReused(replica), "store.replica_reused"),
      (.registryDowngrade(stored: 3, current: 1), "store.registry_downgrade"), (.sequenceExhausted, "store.sequence_exhausted"), (.aborted(Underlying()), "store.aborted"),
    ]
    for (error, code) in cases { #expect(error.code == code) }
  }

  @Test("should include the underlying message in the description")
  func shouldIncludeMessageInDescription() {
    #expect(StoreError.database("disk full").errorDescription == "Database failure: disk full")
  }

  @Test("should pass a store error through and keep any other error as the aborted cause")
  func shouldConvertErrors() {
    guard case .entityPurged = StoreError(converting: StoreError.entityPurged(EntityRef(kind: Fixture.note, key: Fixture.key("k1")))) else {
      Issue.record("a store error should pass through")
      return
    }
    guard case .aborted(let underlying) = StoreError(converting: Underlying()) else {
      Issue.record("another error should be kept as the cause")
      return
    }
    #expect(underlying is Underlying)
  }

  @Test("should describe a database failure without the statement's arguments")
  func shouldHideStatementArguments() async throws {
    let store = try StoreFixture.open()
    let secret = "secret-record-content"
    _ = try await store.write { transaction in try transaction.set(EntityRef(kind: Fixture.note, key: Fixture.key("k1")), ["title": .string(secret)]) }
    let error = await #expect(throws: StoreError.self) {
      try await store.write { transaction in
        try transaction.database.execute(sql: "INSERT INTO change_log (seq, line) VALUES (1, ?)", arguments: [Data(secret.utf8)])
      }
    }
    guard case .database(let message) = error else { throw StoreTestFailure.unexpectedState }
    #expect(message.contains("UNIQUE"))
    #expect(!(error?.description.contains(secret) ?? true))
  }
}
