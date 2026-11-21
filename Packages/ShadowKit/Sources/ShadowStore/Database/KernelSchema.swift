import Foundation
import GRDB
import ShadowCore

enum KernelSchema {
  static let migrationIdentifier = "com.shadow.library.shadowstore.kernel.1"
  static let relayMigrationIdentifier = "com.shadow.library.shadowstore.kernel.2"
  static let stateTables = ["field_state", "appended_item", "revision", "tombstone", "foreign_record", "opaque_line"]
  static let changeLogTable = "change_log"

  static func migrator(_ extra: [StoreMigration]) throws(StoreError) -> DatabaseMigrator {
    var seen = [migrationIdentifier, relayMigrationIdentifier]
    for migration in extra {
      // GRDB keys migrations by Swift String and traps on a duplicate, so uniqueness is checked under the same equality first.
      guard !seen.contains(migration.identifier) else { throw .duplicateMigration(migration.identifier) }
      seen.append(migration.identifier)
    }
    var migrator = DatabaseMigrator()
    migrator.registerMigration(migrationIdentifier, migrate: create)
    migrator.registerMigration(relayMigrationIdentifier, migrate: addRelay)
    for migration in extra { migrator.registerMigration(migration.identifier, migrate: migration.migrate) }
    return migrator
  }

  private static func create(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE kernel_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          replica TEXT NOT NULL,
          next_sequence INTEGER NOT NULL CHECK (next_sequence >= 1),
          clock TEXT,
          observed TEXT,
          acknowledged TEXT,
          registry_version INTEGER NOT NULL,
          registry BLOB NOT NULL
        ) STRICT;
        CREATE TABLE field_state (
          scope INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, slot INTEGER NOT NULL, name BLOB NOT NULL, value BLOB NOT NULL, clock TEXT NOT NULL,
          PRIMARY KEY (scope, kind, key, slot, name)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE appended_item (
          scope INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, item BLOB NOT NULL, clock TEXT NOT NULL,
          PRIMARY KEY (scope, kind, key)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE revision (
          scope INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, id TEXT NOT NULL, item BLOB NOT NULL, generation INTEGER NOT NULL,
          PRIMARY KEY (scope, kind, key, id)
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX revision_rank ON revision (scope, kind, key, generation, id);
        CREATE TABLE tombstone (
          scope INTEGER NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, clock TEXT NOT NULL,
          PRIMARY KEY (scope, kind, key)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE foreign_record (
          scope INTEGER NOT NULL, bytes BLOB NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, role INTEGER NOT NULL,
          PRIMARY KEY (scope, bytes)
        ) STRICT, WITHOUT ROWID;
        CREATE INDEX foreign_record_entity ON foreign_record (scope, kind, key, role);
        CREATE TABLE opaque_line (
          scope INTEGER NOT NULL, bytes BLOB NOT NULL,
          PRIMARY KEY (scope, bytes)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE change_log (
          seq INTEGER PRIMARY KEY,
          line BLOB NOT NULL
        ) STRICT;
        """)
  }

  /// A relayed row carries another write's record unchanged, so a rebuild never re-stamps it and the clock check never weighs it.
  private static func addRelay(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE change_log ADD COLUMN relayed INTEGER NOT NULL DEFAULT 0 CHECK (relayed IN (0, 1))")
  }

  static func clear(_ scope: StateScope, in db: Database) throws {
    for table in stateTables { try db.execute(sql: "DELETE FROM \(table) WHERE scope = ?", arguments: [scope.rawValue]) }
  }
}

/// Clocks are compared as text in SQL: their fixed-width form sorts exactly as `HLCTimestamp` does.
struct KernelRow {
  var replica: ReplicaID
  var nextSequence: Int64
  var clock: HLCTimestamp?
  var observed: HLCTimestamp?
  var acknowledged: HLCTimestamp?
  var registryVersion: Int
  var registry: Data

  var rebuildFloor: HLCTimestamp? {
    [observed, acknowledged].compactMap(\.self).max()
  }

  static func prepare(_ db: Database, registry: SchemaRegistry, mint: () -> ReplicaID) throws -> KernelRow {
    if let row = try loadIfPresent(db) {
      guard row.registryVersion <= registry.version else { throw StoreError.registryDowngrade(stored: row.registryVersion, current: registry.version) }
      return row
    }
    let row = KernelRow(
      replica: mint(), nextSequence: 1, clock: nil, observed: nil, acknowledged: nil, registryVersion: registry.version, registry: registry.canonicalDescription())
    try db.execute(
      sql: "INSERT INTO kernel_state (id, replica, next_sequence, clock, observed, acknowledged, registry_version, registry) VALUES (1, ?, 1, NULL, NULL, NULL, ?, ?)",
      arguments: [row.replica.description, Int64(registry.version), row.registry])
    return row
  }

  func storedRegistry() throws(StoreError) -> SchemaRegistry {
    let decoded: SchemaRegistry
    do {
      decoded = try SchemaRegistry(canonicalDescription: registry)
    } catch {
      throw .corruptStore("the stored registry description is malformed")
    }
    guard decoded.version == registryVersion else { throw .corruptStore("the stored registry description does not match the stored version") }
    return decoded
  }

  static func load(_ db: Database) throws -> KernelRow {
    guard let row = try loadIfPresent(db) else { throw StoreError.corruptStore("the kernel state row is missing") }
    return row
  }

  static func takeSequence(_ db: Database) throws -> Int64 {
    let sequence = try load(db).nextSequence
    guard sequence < Int64.max else { throw StoreError.sequenceExhausted }
    try db.storeExecute("UPDATE kernel_state SET next_sequence = ? WHERE id = 1", [sequence + 1])
    return sequence
  }

  static func saveClock(_ clock: HLCTimestamp, in db: Database) throws {
    try db.storeExecute("UPDATE kernel_state SET clock = ? WHERE id = 1", [clock.description])
  }

  static func observe(_ clock: HLCTimestamp, ownReplica: ReplicaID, in db: Database) throws {
    guard clock.replica != ownReplica else { return }
    try db.storeExecute("UPDATE kernel_state SET observed = ? WHERE id = 1 AND (observed IS NULL OR observed < ?)", [clock.description, clock.description])
  }

  static func saveRegistry(_ registry: SchemaRegistry, in db: Database) throws {
    try db.storeExecute("UPDATE kernel_state SET registry_version = ?, registry = ? WHERE id = 1", [Int64(registry.version), registry.canonicalDescription()])
  }

  static func acknowledge(_ clock: HLCTimestamp, in db: Database) throws {
    try db.storeExecute("UPDATE kernel_state SET acknowledged = ? WHERE id = 1 AND (acknowledged IS NULL OR acknowledged < ?)", [clock.description, clock.description])
  }

  func saveIdentity(_ db: Database) throws {
    try db.storeExecute("UPDATE kernel_state SET replica = ?, next_sequence = ?, clock = ? WHERE id = 1", [replica.description, nextSequence, clock?.description])
  }

  private static func loadIfPresent(_ db: Database) throws -> KernelRow? {
    guard let row = try db.storeFetchOne("SELECT replica, next_sequence, clock, observed, acknowledged, registry_version, registry FROM kernel_state WHERE id = 1", []) else {
      return nil
    }
    guard let replica = ReplicaID(try row.stored("replica")) else { throw StoreError.corruptStore("the replica id is malformed") }
    let nextSequence: Int64 = try row.stored("next_sequence")
    let clock: String? = try row.stored("clock")
    let observed: String? = try row.stored("observed")
    let acknowledged: String? = try row.stored("acknowledged")
    let registryVersion: Int64 = try row.stored("registry_version")
    let registry: Data = try row.stored("registry")
    guard let version = Int(exactly: registryVersion) else { throw StoreError.corruptStore("the registry version is out of range") }
    return KernelRow(
      replica: replica, nextSequence: nextSequence, clock: try clock.map { text throws(StoreError) in try Stored.clock(text) },
      observed: try observed.map { text throws(StoreError) in try Stored.clock(text) }, acknowledged: try acknowledged.map { text throws(StoreError) in try Stored.clock(text) },
      registryVersion: version, registry: registry)
  }
}
