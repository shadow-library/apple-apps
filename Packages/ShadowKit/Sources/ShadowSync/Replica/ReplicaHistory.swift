import Foundation
import GRDB
import ShadowCore
import ShadowStore

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

  public static func recordSegment(_ point: StreamPoint, first: Int64, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted) VALUES (?, ?, ?, ?, ?, NULL, ?, NULL)
        ON CONFLICT (replica, role, last, tag) DO UPDATE SET first = COALESCE(first, excluded.first)
        """,
      arguments: [replica.description, segment, point.last, point.tag.description, first, millis])
  }

  public static func recordBase(_ point: StreamPoint, parts: Int, replica: ReplicaID, at millis: Int64, in database: Database) throws {
    try database.execute(
      sql: """
        INSERT INTO sync_replica_upload (replica, role, last, tag, first, parts, uploaded, deleted) VALUES (?, ?, ?, ?, NULL, ?, ?, NULL)
        ON CONFLICT (replica, role, last, tag) DO UPDATE SET parts = COALESCE(parts, excluded.parts)
        """,
      arguments: [replica.description, base, point.last, point.tag.description, parts, millis])
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
      sql: "SELECT last, tag, parts FROM sync_replica_upload WHERE replica = ? AND role = ? AND deleted IS NULL AND parts IS NOT NULL ORDER BY last DESC, tag DESC LIMIT 1",
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
