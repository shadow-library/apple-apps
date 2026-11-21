import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private let note = EntityRef(kind: Fixture.note, key: Fixture.key("k1"))

@Suite("VaultStore connection left read-only", TestTimeLimit.standard)
struct StoreReadOnlyStrandTests {
  @Test func shouldWriteAgainOnceAnAccessLeftTheConnectionReadOnly() async throws {
    let store = try StoreFixture.open()
    await #expect(throws: StoreError.self) {
      _ = try await store.write { transaction in
        try transaction.database.execute(sql: "PRAGMA query_only = 1")
        return try transaction.set(note, ["title": "refused"])
      }
    }
    let kept = try await store.write { transaction in try transaction.set(note, ["title": "kept"]) }
    #expect(try await store.allPending == StoreFixture.logged([kept]))
    #expect(try await store.read { transaction in try transaction.state(of: note) } != nil)
  }
}
