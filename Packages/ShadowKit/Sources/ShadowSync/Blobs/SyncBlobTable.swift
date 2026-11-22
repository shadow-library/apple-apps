import Foundation
import GRDB
import ShadowCore
import ShadowStore

enum SyncBlobState: String, Sendable, CaseIterable {
  case pending
  /// Put by this database, which may delete it once nothing refers to it.
  case uploaded
  /// Fetched from storage; another database put it.
  case cached
  /// This database decided to delete its copy in storage and has not seen the delete succeed.
  case deleting
  /// Deleted in storage; the local file is kept for a retention period so a reference arriving late can put it back.
  case deleted
}

struct SyncBlobRow: Sendable, Equatable {
  let id: BlobID
  var state: SyncBlobState
  let syncClass: SyncClass
  let size: Int
  let digest: String
  var parts: Int?
  let added: Int64
  var uploaded: Int64?
  /// When this database first found nothing referring to the blob, how far each stream it had applied (its own included, unsent changes too) reached then,
  /// and which of those streams were retired already.
  var released: Int64?
  var releasePoints: [ReplicaID: Int64]?
  var releaseRetired: Set<ReplicaID> = []
  var deleted: Int64?

  var partKeys: [ObjectKey] {
    guard let parts, VaultPath.isPart(1, of: parts) else { return [] }
    return id.partKeys(parts)
  }

  mutating func hold() {
    released = nil
    releasePoints = nil
    releaseRetired = []
  }

  mutating func release(at millis: Int64, points: [ReplicaID: Int64], retired: Set<ReplicaID>) {
    guard released == nil else { return }
    released = millis
    releasePoints = points
    releaseRetired = retired.intersection(points.keys)
  }
}

enum SyncBlobTable {
  static let migration = StoreMigration(identifier: "com.shadow.library.shadowsync.blob.1") { db in
    let states = SyncBlobState.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    let classes = SyncClass.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    try db.execute(
      sql: """
        CREATE TABLE sync_blob (
          id TEXT PRIMARY KEY,
          state TEXT NOT NULL CHECK (state IN (\(states))),
          sync_class TEXT NOT NULL CHECK (sync_class IN (\(classes))),
          size INTEGER NOT NULL CHECK (size >= 0),
          digest TEXT NOT NULL,
          parts INTEGER CHECK (parts BETWEEN 1 AND \(VaultPath.maximumParts)),
          added INTEGER NOT NULL,
          uploaded INTEGER,
          released INTEGER,
          release_points TEXT,
          release_retired TEXT,
          deleted INTEGER,
          CHECK (state IN ('pending', 'cached') OR parts IS NOT NULL)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE sync_published (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          points TEXT NOT NULL
        ) STRICT;
        """)
  }

  static func insert(_ row: SyncBlobRow, in db: Database) throws {
    try db.execute(sql: "INSERT OR IGNORE INTO sync_blob \(columns) VALUES \(placeholders)", arguments: arguments(row))
  }

  static func save(_ row: SyncBlobRow, in db: Database) throws {
    try db.execute(sql: "INSERT OR REPLACE INTO sync_blob \(columns) VALUES \(placeholders)", arguments: arguments(row))
  }

  static func remove(_ id: BlobID, in db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_blob WHERE id = ?", arguments: [id.description])
  }

  static func load(_ id: BlobID, in db: Database) throws -> SyncBlobRow? {
    try Row.fetchOne(db, sql: "SELECT * FROM sync_blob WHERE id = ?", arguments: [id.description]).map(decode)
  }

  static func rows(in states: Set<SyncBlobState>, in db: Database) throws -> [SyncBlobRow] {
    guard try db.tableExists("sync_blob") else { return [] }
    let list = states.map { "'\($0.rawValue)'" }.joined(separator: ", ")
    return try Row.fetchAll(db, sql: "SELECT * FROM sync_blob WHERE state IN (\(list)) ORDER BY added, id").map(decode)
  }

  /// A re-mint changes whose streams a release must reach, so every release starts again.
  static func restartReleases(in db: Database) throws {
    try db.execute(sql: "UPDATE sync_blob SET released = NULL, release_points = NULL, release_retired = NULL")
  }

  private static let columns = "(id, state, sync_class, size, digest, parts, added, uploaded, released, release_points, release_retired, deleted)"
  private static let placeholders = "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

  private static func arguments(_ row: SyncBlobRow) -> StatementArguments {
    let points = row.releasePoints.map { points in
      String(decoding: CanonicalJSON.encode(.object(Dictionary(uniqueKeysWithValues: points.map { ($0.key.description, JSONValue.int($0.value)) }))), as: UTF8.self)
    }
    let retired = row.releaseRetired.isEmpty ? nil : row.releaseRetired.map(\.description).sorted().joined(separator: ",")
    return [
      row.id.description, row.state.rawValue, row.syncClass.rawValue, row.size, row.digest, row.parts, row.added, row.uploaded, row.released, points, retired,
      row.deleted,
    ]
  }

  private static func decode(_ row: Row) throws -> SyncBlobRow {
    guard let id = BlobID(try row.decode(String.self, forColumn: "id")), let state = SyncBlobState(rawValue: try row.decode(String.self, forColumn: "state")),
      let syncClass = SyncClass(rawValue: try row.decode(String.self, forColumn: "sync_class"))
    else { throw SyncError.corruptState("a blob row is malformed") }
    return SyncBlobRow(
      id: id, state: state, syncClass: syncClass, size: try row.decode(Int.self, forColumn: "size"), digest: try row.decode(String.self, forColumn: "digest"),
      parts: try row.decode(Int?.self, forColumn: "parts"), added: try row.decode(Int64.self, forColumn: "added"),
      uploaded: try row.decode(Int64?.self, forColumn: "uploaded"), released: try row.decode(Int64?.self, forColumn: "released"),
      releasePoints: try points(try row.decode(String?.self, forColumn: "release_points")),
      releaseRetired: try replicas(try row.decode(String?.self, forColumn: "release_retired")), deleted: try row.decode(Int64?.self, forColumn: "deleted"))
  }

  private static func replicas(_ text: String?) throws -> Set<ReplicaID> {
    guard let text else { return [] }
    let replicas = text.split(separator: ",").compactMap { ReplicaID(String($0)) }
    guard replicas.count == text.split(separator: ",").count else { throw SyncError.corruptState("blob release replicas are malformed") }
    return Set(replicas)
  }

  private static func points(_ text: String?) throws -> [ReplicaID: Int64]? {
    guard let text else { return nil }
    guard case .object(let members) = try CanonicalJSON.decode(Data(text.utf8)) else { throw SyncError.corruptState("blob release points are malformed") }
    var points: [ReplicaID: Int64] = [:]
    for (key, value) in members {
      guard let replica = ReplicaID(key), case .int(let last) = value else { throw SyncError.corruptState("blob release points are malformed") }
      points[replica] = last
    }
    return points
  }
}

/// The applied points a manifest states: those of the last moment the change log held no unsent change, so a reader that has every file the manifest's
/// replica had uploaded by then also has everything it wrote before it applied them.
enum SyncPublishedTable {
  static func publishable(current: [ReplicaID: StreamPoint], hasPending: Bool, excluding own: ReplicaID, in db: Database) throws -> [ReplicaID: StreamPoint] {
    guard hasPending else {
      try save(current, in: db)
      return current.filter { $0.key != own }
    }
    return try load(db).filter { $0.key != own }
  }

  static func clear(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_published")
  }

  private static func save(_ points: [ReplicaID: StreamPoint], in db: Database) throws {
    let value = JSONValue.object(Dictionary(uniqueKeysWithValues: points.map { ($0.key.description, CodecFrame.pointValue($0.value)) }))
    try db.execute(
      sql: "INSERT INTO sync_published (id, points) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET points = excluded.points",
      arguments: [String(decoding: CanonicalJSON.encode(value), as: UTF8.self)])
  }

  private static func load(_ db: Database) throws -> [ReplicaID: StreamPoint] {
    guard let text = try String.fetchOne(db, sql: "SELECT points FROM sync_published WHERE id = 1") else { return [:] }
    guard case .object(let members) = try CanonicalJSON.decode(Data(text.utf8)) else { throw SyncError.corruptState("the published points are malformed") }
    var points: [ReplicaID: StreamPoint] = [:]
    for (key, value) in members {
      guard let replica = ReplicaID(key), case .object(let point) = value, case .int(let last)? = point["last"], case .string(let tag)? = point["tag"],
        let contentTag = ContentTag(tag)
      else { throw SyncError.corruptState("the published points are malformed") }
      points[replica] = StreamPoint(last: last, tag: contentTag)
    }
    return points
  }
}

extension SyncClass {
  var rank: Int {
    switch self {
    case .general: 0
    case .activity: 1
    case .health: 2
    }
  }

  /// The class a store's blobs carry: the most restricted class its registry declares.
  static func ofBlobs(in registry: SchemaRegistry) -> SyncClass {
    registry.syncClasses.max { $0.rank < $1.rank } ?? .general
  }
}
