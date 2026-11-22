import Foundation
import GRDB
import ShadowCore
import ShadowTestSupport
import Testing

@testable import ShadowStore

private func migration(_ identifier: String) -> StoreMigration {
  StoreMigration(identifier: identifier) { db in
    try db.execute(sql: "CREATE TABLE IF NOT EXISTS migration_trace (step INTEGER PRIMARY KEY AUTOINCREMENT, identifier TEXT NOT NULL)")
    try db.execute(sql: "INSERT INTO migration_trace (identifier) VALUES (?)", arguments: [identifier])
  }
}

private func trace(_ store: VaultStore) async throws -> [String] {
  try await store.read { transaction in try String.fetchAll(transaction.database, sql: "SELECT identifier FROM migration_trace ORDER BY step") }
}

private struct MigrationFailure: Error {}

@Suite("VaultStore persistence")
struct StorePersistenceTests {
  @Test("should reopen with the same replica, state, pending changes and a continuing sequence")
  func shouldSurviveReopening() async throws {
    try await forAll(iterations: 20) { generator in
      let directory = TemporaryDirectory()
      var factory = ChangeFactory()
      let lines = (0..<generator.int(in: 0...2)).map { _ in generator.opaqueLine() }
      let (replica, vault, own, pending, written) = try await {
        let store = try StoreFixture.open(Fixture.v2, at: .file(directory.storeURL))
        try await store.apply(factory.changes(&generator))
        try await store.keepOpaque(lines)
        let written = try await runLocal((0..<generator.int(in: 1...12)).map { _ in LocalOperation.random(&generator) }, in: store, known: [:]).records.count
        try await store.dropChanges(through: Int64(generator.int(in: 0...3)))
        return (store.replica, try await store.loadState(.vault), try await store.loadState(.own), try await store.allPending, written)
      }()
      let reopened = try StoreFixture.open(Fixture.v2, at: .file(directory.storeURL))
      try #require(reopened.replica == replica)
      try #require(try await reopened.loadState(.vault).digest == vault.digest)
      try #require(try await reopened.loadState(.own).digest == own.digest)
      try #require(try await reopened.allPending == pending)
      let next = try await reopened.write { transaction in try transaction.set(EntityRef(kind: Fixture.note, key: Fixture.key("fresh")), ["origin": "after reopening"]) }
      try #require(next.clock.replica == replica)
      try #require(try await reopened.allPending.last == LoggedChange(sequence: Int64(written) + 1, line: next.canonicalBytes()))
    }
  }

  @Test("should run extra migrations once each, in the order given, after the kernel's")
  func shouldRunMigrationsOnce() async throws {
    let directory = TemporaryDirectory()
    let migrations = [migration("product.b"), migration("product.a")]
    let first = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, migrations: migrations)
    #expect(try await trace(first) == ["product.b", "product.a"])
    let second = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, migrations: migrations + [migration("product.c")])
    #expect(try await trace(second) == ["product.b", "product.a", "product.c"])
    #expect(second.replica == first.replica)
  }

  @Test("should fail to open with a duplicate migration identifier, including the kernel's and a normalisation twin")
  func shouldRefuseDuplicateMigrations() throws {
    let duplicates = [
      [migration("product.a"), migration("product.a")], [migration(KernelSchema.migrationIdentifier)], [migration("caf\u{E9}"), migration("cafe\u{301}")],
    ]
    for migrations in duplicates {
      let error = #expect(throws: StoreError.self) { try VaultStore.open(.inMemory, registry: Fixture.v1, migrations: migrations) }
      #expect(error?.code == "store.duplicate_migration")
    }
  }

  @Test("should report a failing migration as an aborted open and keep nothing of it")
  func shouldReportFailingMigration() async throws {
    let directory = TemporaryDirectory()
    let failing = StoreMigration(identifier: "product.failing") { db in
      try db.execute(sql: "CREATE TABLE half_done (id INTEGER)")
      throw MigrationFailure()
    }
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1, migrations: [failing]) }
    guard case .aborted(let underlying) = error else { throw StoreTestFailure.unexpectedState }
    #expect(underlying is MigrationFailure)
    let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
    let tables = try await store.read { transaction in try String.fetchAll(transaction.database, sql: "SELECT name FROM sqlite_master WHERE name = 'half_done'") }
    #expect(tables.isEmpty)
  }

  @Test("should keep a lower stored registry version for reinterpretation and refuse a downgrade")
  func shouldGuardRegistryVersion() async throws {
    let directory = TemporaryDirectory()
    let version = { (store: VaultStore) in try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT registry_version FROM kernel_state") } }
    let first = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
    #expect(first.storedRegistryVersion == Fixture.v1.version)
    let upgraded = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2)
    #expect(upgraded.storedRegistryVersion == Fixture.v1.version)
    #expect(try await version(upgraded) == Fixture.v2.version)
    _ = try await upgraded.write { transaction in try transaction.database.execute(sql: "UPDATE kernel_state SET registry_version = ?", arguments: [Fixture.v2.version]) }
    let error = #expect(throws: StoreError.self) { try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1) }
    #expect(error?.code == "store.registry_downgrade")
    #expect(try VaultStore.open(.inMemory, registry: Fixture.v2).storedRegistryVersion == Fixture.v2.version)
  }

  @Test("should reopen a populated store without running its migrations again or writing any kernel table")
  func shouldReopenWithoutWriting() async throws {
    let directory = TemporaryDirectory()
    let audit = StoreMigration(identifier: "test.audit") { db in
      try db.execute(sql: "CREATE TABLE write_audit (tableName TEXT NOT NULL)")
      for table in KernelSchema.stateTables + ["kernel_state", "change_log"] {
        for event in ["INSERT", "UPDATE", "DELETE"] {
          try db.execute(sql: "CREATE TRIGGER audit_\(table)_\(event.lowercased()) AFTER \(event) ON \(table) BEGIN INSERT INTO write_audit VALUES ('\(table)'); END")
        }
      }
    }
    let (digest, audited) = try await {
      let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2, migrations: [audit, migration("product.a")])
      var generator = SeededGenerator(seed: 0xC0FFEE)
      var factory = ChangeFactory()
      try await store.apply(factory.changes(&generator, count: 500...500))
      let audited = try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM write_audit") }
      return (try await store.loadState(.vault).digest, audited)
    }()
    #expect((audited ?? 0) > 0)
    for _ in 0..<3 {
      let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v2, migrations: [audit, migration("product.a")])
      #expect(try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM write_audit") } == audited)
      #expect(try await trace(store) == ["product.a"])
      #expect(try await store.loadState(.vault).digest == digest)
    }
  }
}

@Suite("VaultStore closing", TestTimeLimit.standard)
struct StoreClosingTests {
  @Test("should fail every read and write after closing and leave the files for a new store to open")
  func shouldRefuseAccessOnceClosed() async throws {
    let directory = TemporaryDirectory()
    let store = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
    let ref = EntityRef(kind: Fixture.note, key: Fixture.key("kept"))
    _ = try await store.write { transaction in try transaction.set(ref, ["origin": "before closing"]) }

    try store.close()

    await #expect(throws: StoreError.self) { try await store.loadState(.vault) }
    await #expect(throws: StoreError.self) { try await store.write { transaction in try transaction.set(ref, ["origin": "after closing"]) } }
    let reopened = try VaultStore.open(.file(directory.storeURL), registry: Fixture.v1)
    #expect(try await reopened.read { transaction in try transaction.state(of: ref) } != nil)
  }
}
