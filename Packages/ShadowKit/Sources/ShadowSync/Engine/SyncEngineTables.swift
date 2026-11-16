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

  static let heldMigration = StoreMigration(identifier: "shadow.sync.engine.2") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_held (
          replica TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN ('\(segment)', '\(base)')),
          last INTEGER NOT NULL CHECK (last BETWEEN 0 AND \(VaultPath.maximumSequence)),
          tag TEXT NOT NULL,
          size INTEGER NOT NULL CHECK (size >= 0),
          reason TEXT NOT NULL,
          detail TEXT,
          clock TEXT,
          attempts INTEGER NOT NULL CHECK (attempts >= 0),
          waits INTEGER NOT NULL CHECK (waits >= 0),
          unlisted INTEGER NOT NULL CHECK (unlisted >= 0),
          PRIMARY KEY (replica, kind, last, tag)
        ) STRICT, WITHOUT ROWID;
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

  static func load(_ db: Database) throws -> [ReplicaID: SyncAppliedFiles] {
    var files: [ReplicaID: SyncAppliedFiles] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT replica, kind, last, tag FROM sync_applied") {
      guard let replica = ReplicaID(try row.decode(String.self, forColumn: "replica")), let tag = ContentTag(try row.decode(String.self, forColumn: "tag")) else {
        throw SyncError.corruptState("an applied file has a malformed name")
      }
      let point = StreamPoint(last: try row.decode(Int64.self, forColumn: "last"), tag: tag)
      let kind: SyncFileKind = try row.decode(String.self, forColumn: "kind") == SyncEngineSchema.base ? .base : .segment
      files[replica, default: SyncAppliedFiles()].insert(point, kind: kind)
    }
    return files
  }

  static func clear(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_applied")
  }
}

struct SyncAppliedFiles: Sendable, Equatable {
  private(set) var segments: Set<StreamPoint> = []
  private(set) var bases: Set<StreamPoint> = []
  private var segmentEnds: Set<Int64> = []
  private var highestBase: Int64 = -1

  var isEmpty: Bool { segments.isEmpty && bases.isEmpty }

  mutating func insert(_ point: StreamPoint, kind: SyncFileKind) {
    switch kind {
    case .segment:
      segments.insert(point)
      segmentEnds.insert(point.last)
    case .base:
      bases.insert(point)
      highestBase = max(highestBase, point.last)
    }
  }

  /// Coverage is by sequence number, not tag: under a fork that can cost order, never data, because every base and every segment is applied.
  func satisfies(_ point: StreamPoint) -> Bool {
    segments.contains(point) || highestBase >= point.last
  }

  /// Decides from a file name alone, before any download, whether a segment starting at `first` can have a satisfied predecessor.
  func maySatisfyPredecessor(ofFirst first: Int64) -> Bool {
    first == 1 || segmentEnds.contains(first - 1) || highestBase >= first - 1
  }
}

struct SyncHeldFile: Sendable, Equatable {
  let id: SyncFileID
  var size: Int
  var reason: SyncHoldReason
  var clock: HLCTimestamp?
  var attempts: Int
  var waits: Int
  var unlisted: Int
}

enum SyncHeldTable {
  /// A row whose reason this version does not know is ignored, as if the file had never been held.
  static func load(_ db: Database) throws -> [SyncFileID: SyncHeldFile] {
    var files: [SyncFileID: SyncHeldFile] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT replica, kind, last, tag, size, reason, detail, clock, attempts, waits, unlisted FROM sync_held") {
      guard let file = try decode(row) else { continue }
      files[file.id] = file
    }
    return files
  }

  static func replace(with files: some Sequence<SyncHeldFile>, in db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_held")
    for file in files { try save(file, in: db) }
  }

  static func save(_ file: SyncHeldFile, in db: Database) throws {
    let (reason, detail) = encode(file.reason)
    try db.execute(
      sql: """
        INSERT INTO sync_held (replica, kind, last, tag, size, reason, detail, clock, attempts, waits, unlisted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (replica, kind, last, tag) DO UPDATE SET
          size = excluded.size, reason = excluded.reason, detail = excluded.detail, clock = excluded.clock, attempts = excluded.attempts, waits = excluded.waits,
          unlisted = excluded.unlisted
        """,
      arguments: [
        file.id.replica.description, file.id.kind.rawValue, file.id.point.last, file.id.point.tag.description, file.size, reason, detail, file.clock?.description,
        file.attempts, file.waits, file.unlisted,
      ])
  }

  static func remove(_ id: SyncFileID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM sync_held WHERE replica = ? AND kind = ? AND last = ? AND tag = ?",
      arguments: [id.replica.description, id.kind.rawValue, id.point.last, id.point.tag.description])
  }

  private static func encode(_ reason: SyncHoldReason) -> (String, String?) {
    switch reason {
    case .missingKey(let key): ("missing-key", key.description)
    case .unauthenticated: ("unauthenticated", nil)
    case .malformed: ("malformed", nil)
    case .clockAhead: ("clock-ahead", nil)
    case .waitingForPredecessor: ("waiting-for-predecessor", nil)
    case .waitingForDependency(let replica): ("waiting-for-dependency", replica.description)
    case .incompleteBase(let missing): ("incomplete-base", missing.map(String.init).joined(separator: ","))
    case .rejected: ("rejected", nil)
    case .unsupported: ("unsupported", nil)
    case .unavailable: ("unavailable", nil)
    }
  }

  private static func decode(_ row: Row) throws -> SyncHeldFile? {
    guard
      let replica = ReplicaID(try row.decode(String.self, forColumn: "replica")),
      let kind = SyncFileKind(rawValue: try row.decode(String.self, forColumn: "kind")),
      let tag = ContentTag(try row.decode(String.self, forColumn: "tag"))
    else { throw SyncError.corruptState("a held file has a malformed name") }
    let detail: String? = try row.decode(forColumn: "detail")
    let clockText: String? = try row.decode(forColumn: "clock")
    let clock = try clockText.map { text in
      guard let clock = HLCTimestamp(text) else { throw SyncError.corruptState("a held file has a malformed clock") }
      return clock
    }
    guard let reason = reason(try row.decode(String.self, forColumn: "reason"), detail: detail) else { return nil }
    return SyncHeldFile(
      id: SyncFileID(replica: replica, kind: kind, point: StreamPoint(last: try row.decode(Int64.self, forColumn: "last"), tag: tag)),
      size: try row.decode(Int.self, forColumn: "size"), reason: reason, clock: clock, attempts: try row.decode(Int.self, forColumn: "attempts"),
      waits: try row.decode(Int.self, forColumn: "waits"), unlisted: try row.decode(Int.self, forColumn: "unlisted"))
  }

  static func reason(_ text: String, detail: String?) -> SyncHoldReason? {
    switch text {
    case "missing-key": detail.flatMap(KeyID.init).map { .missingKey($0) }
    case "unauthenticated": .unauthenticated
    case "malformed": .malformed
    case "clock-ahead": .clockAhead
    case "waiting-for-predecessor": .waitingForPredecessor
    case "waiting-for-dependency": detail.flatMap(ReplicaID.init).map { .waitingForDependency($0) }
    case "incomplete-base": .incompleteBase(missing: (detail ?? "").split(separator: ",").compactMap { Int($0) })
    case "rejected": .rejected
    case "unsupported": .unsupported
    case "unavailable": .unavailable
    default: nil
    }
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
