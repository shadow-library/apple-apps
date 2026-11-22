import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

@Suite("VaultStore stored bytes", TestTimeLimit.standard)
struct StoreStoredBytesTests {
  private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))
  private let other = EntityRef(kind: Fixture.note, key: Fixture.key("k2"))
  private let message = EntityRef(kind: Fixture.message, key: Fixture.key("m1"))
  private let draft = EntityRef(kind: Fixture.draft, key: Fixture.key("d1"))
  private let marker = String(repeating: "0123456789abcdef", count: 4)

  private func visited(_ store: VaultStore) async throws -> [String] {
    try await store.read { transaction in
      var texts: [String] = []
      try transaction.forEachStoredBytes { bytes in
        texts.append(String(decoding: bytes, as: UTF8.self))
        return true
      }
      return texts
    }
  }

  private func remote(_ fields: [String: JSONValue], ref: EntityRef, clock: ManualClock) -> Data {
    let stamp = must(HLCTimestamp(wallMillis: clock.millis + 1_000, counter: 0, replica: Fixture.replicas[1]), "stamp")
    return Fixture.change(.set, ref.kind, ref.key, clock: stamp, fields: fields).canonicalBytes()
  }

  private func settled(_ store: VaultStore) async throws {
    let last = try await store.read { try $0.lastSequence() }
    try await store.dropChanges(through: last)
  }

  @Test("should visit the merged state and the unsent changes but not a replica's own superseded writes")
  func shouldVisitMergedState() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(Fixture.v2, clock: clock)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "own-value"]) }
    try await settled(store)
    _ = try await store.applyRemote([remote(["title": "remote-value"], ref: note, clock: clock)])
    _ = try await store.write { transaction in try transaction.set(other, ["title": "pending-value"]) }

    let texts = try await visited(store)

    #expect(texts.contains { $0.contains("remote-value") })
    #expect(texts.contains { $0.contains("pending-value") })
    #expect(texts.contains("k1"))
    #expect(!texts.contains { $0.contains("own-value") })
    #expect(try await store.read { try $0.hasPendingChanges() })
  }

  @Test("should visit an appended item")
  func shouldVisitAppendedItems() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    _ = try await store.write { [message, marker] transaction in try transaction.append(message, item: ["image": .string(marker)]) }
    try await settled(store)

    #expect(try await visited(store).contains { $0.contains("\"\(marker)\"") })
  }

  @Test("should visit a revision's body")
  func shouldVisitRevisions() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    _ = try await store.write { [draft, marker] transaction in try transaction.revise(draft, body: ["image": .string(marker)]) }
    try await settled(store)

    #expect(try await visited(store).contains { $0.contains("\"\(marker)\"") })
  }

  @Test("should visit a field this registry does not declare, kept for a newer app")
  func shouldVisitForeignRecords() async throws {
    let clock = ManualClock()
    let store = try StoreFixture.open(Fixture.v2, clock: clock)
    _ = try await store.applyRemote([remote(["attachment": .string(marker)], ref: note, clock: clock)])

    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM foreign_record") } == 1)
    #expect(try await visited(store).contains { $0.contains("\"\(marker)\"") })
  }

  @Test("should visit a line no change record parses from")
  func shouldVisitOpaqueLines() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    _ = try await store.applyRemote([Data("{\"image\":\"\(marker)\"}".utf8)])

    #expect(try await store.read { try Int.fetchOne($0.database, sql: "SELECT COUNT(*) FROM opaque_line") } == 1)
    #expect(try await visited(store).contains { $0.contains("\"\(marker)\"") })
  }

  @Test("should not visit a purged entity's values")
  func shouldSkipPurged() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    _ = try await store.write { transaction in try transaction.set(note, ["title": "gone-value"]) }
    _ = try await store.write { transaction in try transaction.purge(note) }
    try await settled(store)

    #expect(!(try await visited(store)).contains { $0.contains("gone-value") })
    #expect(try await store.read { try $0.hasPendingChanges() } == false)
  }

  @Test("should stop as soon as the visitor asks and report the last logged sequence")
  func shouldStopEarly() async throws {
    let store = try StoreFixture.open(Fixture.v2)
    _ = try await store.write { transaction in
      _ = try transaction.set(note, ["title": "a"])
      _ = try transaction.set(other, ["title": "b"])
    }

    let count = try await store.read { transaction in
      var count = 0
      try transaction.forEachStoredBytes { _ in
        count += 1
        return false
      }
      return count
    }

    #expect(count == 1)
    #expect(try await store.read { try $0.lastSequence() } == 2)
  }
}
