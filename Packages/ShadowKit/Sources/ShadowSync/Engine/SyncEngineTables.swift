import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum SyncEngineSchema {
  static let segment = "segment"
  static let base = "base"

  static let migration = StoreMigration(identifier: "shadow.sync.engine.1") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_outbox (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          replica TEXT NOT NULL,
          object_key TEXT NOT NULL,
          first INTEGER NOT NULL CHECK (first >= 1),
          last INTEGER NOT NULL CHECK (last BETWEEN first AND \(VaultPath.maximumSequence)),
          tag TEXT NOT NULL,
          data BLOB NOT NULL,
          saved INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE sync_applied (
          replica TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('\(segment)', '\(base)')),
          last INTEGER NOT NULL CHECK (last BETWEEN 0 AND \(VaultPath.maximumSequence)),
          tag TEXT NOT NULL,
          first INTEGER CHECK (first BETWEEN 1 AND last),
          applied INTEGER NOT NULL,
          PRIMARY KEY (replica, kind, last, tag),
          CHECK (kind = '\(base)' OR first IS NOT NULL)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE sync_floor (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          key_floor TEXT,
          minimum_schema INTEGER CHECK (minimum_schema >= 0)
        ) STRICT;
        """)
  }
}

struct SyncOutboxEntry: Sendable, Equatable {
  let replica: ReplicaID
  let key: ObjectKey
  let first: Int64
  let last: Int64
  let tag: ContentTag
  let data: Data

  var point: StreamPoint { StreamPoint(last: last, tag: tag) }
}

enum SyncOutbox {
  static func load(_ db: Database) throws -> SyncOutboxEntry? {
    guard let row = try Row.fetchOne(db, sql: "SELECT replica, object_key, first, last, tag, data FROM sync_outbox WHERE id = 1") else { return nil }
    guard
      let replica = ReplicaID(try row.decode(String.self, forColumn: "replica")),
      let key = ObjectKey(try row.decode(String.self, forColumn: "object_key")),
      let tag = ContentTag(try row.decode(String.self, forColumn: "tag"))
    else { throw SyncError.corruptState("the saved upload has a malformed name") }
    let entry = SyncOutboxEntry(
      replica: replica, key: key, first: try row.decode(Int64.self, forColumn: "first"), last: try row.decode(Int64.self, forColumn: "last"), tag: tag,
      data: try row.decode(Data.self, forColumn: "data"))
    guard VaultPath.classify(key) == .segment(replica, first: entry.first, last: entry.last, tag: tag) else {
      throw SyncError.corruptState("the saved upload's name does not match its sequences")
    }
    return entry
  }

  static func save(_ entry: SyncOutboxEntry, at millis: Int64, in db: Database) throws {
    guard try load(db) == nil else { throw SyncError.corruptState("an upload is already in flight") }
    try db.execute(
      sql: "INSERT INTO sync_outbox (id, replica, object_key, first, last, tag, data, saved) VALUES (1, ?, ?, ?, ?, ?, ?, ?)",
      arguments: [entry.replica.description, entry.key.rawValue, entry.first, entry.last, entry.tag.description, entry.data, millis])
  }

  static func clear(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_outbox")
  }
}

enum SyncAppliedTable {
  static func record(_ point: StreamPoint, first: Int64?, isBase: Bool, replica: ReplicaID, at millis: Int64, in db: Database) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO sync_applied (replica, kind, last, tag, first, applied) VALUES (?, ?, ?, ?, ?, ?)",
      arguments: [replica.description, isBase ? SyncEngineSchema.base : SyncEngineSchema.segment, point.last, point.tag.description, first, millis])
  }

  /// The newest point applied of each replica; a base at 0 is not a stream point a header can name.
  static func points(excluding own: ReplicaID, in db: Database) throws -> [ReplicaID: StreamPoint] {
    var points: [ReplicaID: StreamPoint] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT replica, last, tag FROM sync_applied WHERE last >= 1") {
      guard let replica = ReplicaID(try row.decode(String.self, forColumn: "replica")), let tag = ContentTag(try row.decode(String.self, forColumn: "tag")) else {
        throw SyncError.corruptState("an applied file has a malformed name")
      }
      guard replica != own else { continue }
      let point = StreamPoint(last: try row.decode(Int64.self, forColumn: "last"), tag: tag)
      points[replica] = max(points[replica] ?? point, point)
    }
    return points
  }

  static func clear(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_applied")
  }
}

struct SyncFloors: Sendable, Equatable {
  var key: KeyID?
  var schema: Int?
}

enum SyncFloorTable {
  static func load(_ db: Database) throws -> SyncFloors {
    guard let row = try Row.fetchOne(db, sql: "SELECT key_floor, minimum_schema FROM sync_floor WHERE id = 1") else { return SyncFloors() }
    let text: String? = try row.decode(forColumn: "key_floor")
    let key = try text.map { text in
      guard let key = KeyID(text) else { throw SyncError.corruptState("the saved key floor is not a key id") }
      return key
    }
    return SyncFloors(key: key, schema: try row.decode(Int?.self, forColumn: "minimum_schema"))
  }

  static func raise(to floors: SyncFloors, in db: Database) throws -> SyncFloors {
    let saved = try load(db)
    let raised = SyncFloors(key: [saved.key, floors.key].compactMap(\.self).max(), schema: [saved.schema, floors.schema].compactMap(\.self).max())
    guard raised != saved else { return saved }
    try db.execute(
      sql: """
        INSERT INTO sync_floor (id, key_floor, minimum_schema) VALUES (1, ?, ?)
        ON CONFLICT (id) DO UPDATE SET key_floor = excluded.key_floor, minimum_schema = excluded.minimum_schema
        """,
      arguments: [raised.key?.description, raised.schema])
    return raised
  }
}
