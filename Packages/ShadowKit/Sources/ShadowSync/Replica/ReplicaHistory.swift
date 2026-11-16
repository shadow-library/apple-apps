import Foundation
import GRDB
import ShadowCore
import ShadowStore

struct SyncUploadEntry: Sendable, Equatable {
  let isBase: Bool
  let point: StreamPoint
  let first: Int64?
  let parts: Int?
  let uploaded: Int64
  let deleted: Int64?
  let completed: Int64?

  var isLive: Bool { deleted == nil }
  var isCompleteBase: Bool { isBase && completed != nil }
}

public enum ReplicaHistory {
  private static let segment = "segment"
  private static let base = "base"

  public static let migration = StoreMigration(identifier: "shadow.sync.history.1") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_replica_upload (
          replica TEXT NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('\(segment)', '\(base)')),
          last INTEGER NOT NULL CHECK (last BETWEEN 0 AND \(VaultPath.maximumSequence)),
          tag TEXT NOT NULL,
          first INTEGER CHECK (first BETWEEN 1 AND last),
          parts INTEGER CHECK (parts BETWEEN 1 AND \(VaultPath.maximumParts)),
          uploaded INTEGER NOT NULL,
          deleted INTEGER,
          PRIMARY KEY (replica, role, last, tag),
          CHECK (role = '\(base)' OR last >= 1)
        ) STRICT, WITHOUT ROWID;
        """)
  }

  /// A base row records its part count from the moment it is announced; `completed` orders completions, so the current base is the one completed last.
  public static let completionMigration = StoreMigration(identifier: "shadow.sync.history.2") { db in
    try db.execute(
      sql: """
        ALTER TABLE sync_replica_upload ADD COLUMN completed INTEGER CHECK (completed >= 1);
        UPDATE sync_replica_upload AS b SET completed = (
          SELECT COUNT(*) FROM sync_replica_upload AS o
          WHERE o.role = '\(base)' AND o.parts IS NOT NULL AND (o.uploaded, o.last, o.tag) <= (b.uploaded, b.last, b.tag)
        ) WHERE role = '\(base)' AND parts IS NOT NULL;
        """)
  }

  public static func recordSegment(_ point: StreamPoint, first: Int64, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL)
        ON CONFLICT (replica, role, last, tag) DO UPDATE SET first = COALESCE(first, excluded.first)
        """,
      arguments: [replica.description, segment, point.last, point.tag.description, first, millis])
  }

  /// Completes a base, recording it as such if it was never announced; a base completed once keeps its place in the completion order.
  public static func recordBase(_ point: StreamPoint, parts: Int, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted, completed)
        VALUES (?, ?, ?, ?, NULL, ?, ?, NULL, (SELECT COALESCE(MAX(completed), 0) + 1 FROM sync_replica_upload))
        ON CONFLICT (replica, role, last, tag) DO UPDATE SET parts = COALESCE(parts, excluded.parts), completed = COALESCE(completed, excluded.completed)
        """,
      arguments: [replica.description, base, point.last, point.tag.description, parts, millis])
  }

  /// Recorded before the first part is put, so the self-check knows the base and cleanup knows its part names; fails if the point was ever recorded.
  static func announceBase(_ point: StreamPoint, parts: Int, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: "INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted, completed) VALUES (?, ?, ?, ?, NULL, ?, ?, NULL, NULL)",
      arguments: [replica.description, base, point.last, point.tag.description, parts, millis])
  }

  static func entries(of replica: ReplicaID, in database: Database) throws -> [SyncUploadEntry] {
    try Row.fetchAll(
      database, sql: "SELECT role, last, tag, first, parts, uploaded, deleted, completed FROM sync_replica_upload WHERE replica = ? ORDER BY role, last, tag",
      arguments: [replica.description]
    ).map { row in
      SyncUploadEntry(
        isBase: try row.decode(String.self, forColumn: "role") == base, point: try streamPoint(row), first: try row.decode(Int64?.self, forColumn: "first"),
        parts: try row.decode(Int?.self, forColumn: "parts"), uploaded: try row.decode(Int64.self, forColumn: "uploaded"),
        deleted: try row.decode(Int64?.self, forColumn: "deleted"), completed: try row.decode(Int64?.self, forColumn: "completed"))
    }
  }

  /// A deletion of a file not yet recorded is still remembered, so a listing that lags behind the delete is not mistaken for another writer.
  public static func markDeleted(_ point: StreamPoint, isBase: Bool, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted) VALUES (?, ?, ?, ?, NULL, NULL, ?, ?)
        ON CONFLICT (replica, role, last, tag) DO UPDATE SET deleted = COALESCE(deleted, excluded.deleted)
        """,
      arguments: [replica.description, isBase ? base : segment, point.last, point.tag.description, millis, millis])
  }

  public static func uploads(of replica: ReplicaID, in database: Database) throws -> ReplicaUploadHistory {
    var history = ReplicaUploadHistory()
    for row in try Row.fetchAll(database, sql: "SELECT role, last, tag FROM sync_replica_upload WHERE replica = ?", arguments: [replica.description]) {
      let point = try streamPoint(row)
      if try row.decode(String.self, forColumn: "role") == base {
        history.bases.insert(point)
      } else {
        history.segments.insert(point)
      }
    }
    return history
  }

  public static func head(of replica: ReplicaID, in database: Database) throws -> StreamPoint? {
    let row = try Row.fetchOne(
      database, sql: "SELECT last, tag FROM sync_replica_upload WHERE replica = ? AND role = ? ORDER BY last DESC, tag DESC LIMIT 1",
      arguments: [replica.description, segment])
    return try row.map(streamPoint)
  }

  public static func currentBase(of replica: ReplicaID, in database: Database) throws -> BaseReference? {
    let row = try Row.fetchOne(
      database,
      sql: "SELECT last, tag, parts FROM sync_replica_upload WHERE replica = ? AND role = ? AND deleted IS NULL AND completed IS NOT NULL ORDER BY completed DESC LIMIT 1",
      arguments: [replica.description, base])
    guard let row else { return nil }
    let point = try streamPoint(row)
    guard let reference = BaseReference(upTo: point.last, tag: point.tag, parts: try row.decode(Int.self, forColumn: "parts")) else {
      throw ReplicaLifecycleError.corruptState("a recorded base is out of range")
    }
    return reference
  }

  public static func clear(replica: ReplicaID, in database: Database) throws {
    try database.execute(sql: "DELETE FROM sync_replica_upload WHERE replica = ?", arguments: [replica.description])
  }

  private static func streamPoint(_ row: Row) throws -> StreamPoint {
    guard let tag = ContentTag(try row.decode(String.self, forColumn: "tag")) else { throw ReplicaLifecycleError.corruptState("a recorded upload has a malformed tag") }
    return StreamPoint(last: try row.decode(Int64.self, forColumn: "last"), tag: tag)
  }
}
