import Foundation
import GRDB
import ShadowCore
import ShadowStore

extension SyncEngineSchema {
  static let adoptionMigration = StoreMigration(identifier: "shadow.sync.engine.4") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_adoption (
          adopter TEXT NOT NULL,
          adopted TEXT NOT NULL,
          phase TEXT NOT NULL CHECK (phase IN ('\(SyncAdoptionPhase.folding.rawValue)', '\(SyncAdoptionPhase.published.rawValue)', '\(SyncAdoptionPhase.finished.rawValue)')),
          through INTEGER CHECK (through BETWEEN 0 AND \(VaultPath.maximumSequence)),
          base_up_to INTEGER CHECK (base_up_to BETWEEN 0 AND \(VaultPath.maximumSequence)),
          at INTEGER CHECK (at BETWEEN 1 AND \(VaultPath.maximumSequence)),
          completed_before INTEGER CHECK (completed_before >= 0),
          PRIMARY KEY (adopter, adopted),
          CHECK (phase <> '\(SyncAdoptionPhase.published.rawValue)' OR (through IS NOT NULL AND at IS NOT NULL AND completed_before IS NOT NULL))
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE sync_adoption_fold (
          adopter TEXT NOT NULL,
          adopted TEXT NOT NULL,
          object_key TEXT NOT NULL,
          first INTEGER CHECK (first BETWEEN 1 AND last),
          last INTEGER NOT NULL CHECK (last BETWEEN 0 AND \(VaultPath.maximumSequence)),
          published INTEGER NOT NULL CHECK (published IN (0, 1)),
          unlisted INTEGER,
          PRIMARY KEY (adopter, adopted, object_key)
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE sync_adoption_gap (
          adopter TEXT NOT NULL,
          adopted TEXT NOT NULL,
          up_to INTEGER NOT NULL CHECK (up_to BETWEEN 0 AND \(VaultPath.maximumSequence)),
          tag TEXT NOT NULL,
          parts INTEGER NOT NULL CHECK (parts BETWEEN 1 AND \(VaultPath.maximumParts)),
          seen INTEGER NOT NULL,
          PRIMARY KEY (adopter, adopted, up_to, tag, parts)
        ) STRICT, WITHOUT ROWID;
        """)
  }
}

enum SyncAdoptionPhase: String, Sendable {
  case folding
  case published
  case finished
}

/// `through` and `baseUpTo` only grow across the passes over one replica; `at` and `completedBefore` belong to the fact published last.
struct SyncAdoptionRow: Sendable, Equatable {
  let adopted: ReplicaID
  var phase: SyncAdoptionPhase
  var through: Int64?
  var baseUpTo: Int64?
  var at: Int64?
  var completedBefore: Int64?
}

/// A folded file; `first` is nil for a base part, which covers its sequence numbers only together with every other part of its base.
struct SyncFoldRow: Sendable, Equatable {
  let adopted: ReplicaID
  let key: ObjectKey
  let first: Int64?
  let last: Int64
  var published = false
  var unlisted: Int64?
}

struct SyncBaseName: Sendable, Hashable {
  let upTo: Int64
  let tag: ContentTag
  let parts: Int

  func keys(of replica: ReplicaID) -> [ObjectKey] {
    (1...parts).map { VaultPath.basePart(replica, upTo: upTo, tag: tag, part: $0, parts: parts) }
  }
}

/// Every row names the replica that made it, so rows a re-mint outside the engine left behind are never read as this replica's.
enum SyncAdoptionTable {
  static func rows(of adopter: ReplicaID, in db: Database) throws -> [ReplicaID: SyncAdoptionRow] {
    var rows: [ReplicaID: SyncAdoptionRow] = [:]
    let sql = "SELECT adopted, phase, through, base_up_to, at, completed_before FROM sync_adoption WHERE adopter = ?"
    for row in try Row.fetchAll(db, sql: sql, arguments: [adopter.description]) {
      guard let adopted = ReplicaID(try row.decode(String.self, forColumn: "adopted")), let phase = SyncAdoptionPhase(rawValue: try row.decode(String.self, forColumn: "phase"))
      else { throw SyncError.corruptState("an adoption row is malformed") }
      rows[adopted] = SyncAdoptionRow(
        adopted: adopted, phase: phase, through: try row.decode(Int64?.self, forColumn: "through"), baseUpTo: try row.decode(Int64?.self, forColumn: "base_up_to"),
        at: try row.decode(Int64?.self, forColumn: "at"), completedBefore: try row.decode(Int64?.self, forColumn: "completed_before"))
    }
    return rows
  }

  static func save(_ row: SyncAdoptionRow, of adopter: ReplicaID, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO sync_adoption (adopter, adopted, phase, through, base_up_to, at, completed_before) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (adopter, adopted) DO UPDATE SET
          phase = excluded.phase, through = excluded.through, base_up_to = excluded.base_up_to, at = excluded.at, completed_before = excluded.completed_before
        """,
      arguments: [adopter.description, row.adopted.description, row.phase.rawValue, row.through, row.baseUpTo, row.at, row.completedBefore])
  }

  static func folds(of adopter: ReplicaID, in db: Database) throws -> [ReplicaID: [ObjectKey: SyncFoldRow]] {
    var folds: [ReplicaID: [ObjectKey: SyncFoldRow]] = [:]
    let sql = "SELECT adopted, object_key, first, last, published, unlisted FROM sync_adoption_fold WHERE adopter = ?"
    for row in try Row.fetchAll(db, sql: sql, arguments: [adopter.description]) {
      guard let adopted = ReplicaID(try row.decode(String.self, forColumn: "adopted")), let key = ObjectKey(try row.decode(String.self, forColumn: "object_key")) else {
        throw SyncError.corruptState("a fold row is malformed")
      }
      folds[adopted, default: [:]][key] = SyncFoldRow(
        adopted: adopted, key: key, first: try row.decode(Int64?.self, forColumn: "first"), last: try row.decode(Int64.self, forColumn: "last"),
        published: try row.decode(Bool.self, forColumn: "published"), unlisted: try row.decode(Int64?.self, forColumn: "unlisted"))
    }
    return folds
  }

  static func recordFold(_ fold: SyncFoldRow, of adopter: ReplicaID, in db: Database) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO sync_adoption_fold (adopter, adopted, object_key, first, last, published) VALUES (?, ?, ?, ?, ?, 0)",
      arguments: [adopter.description, fold.adopted.description, fold.key.rawValue, fold.first, fold.last])
  }

  static func publishFolds(of adopted: ReplicaID, by adopter: ReplicaID, in db: Database) throws {
    try db.execute(sql: "UPDATE sync_adoption_fold SET published = 1 WHERE adopter = ? AND adopted = ?", arguments: [adopter.description, adopted.description])
  }

  /// Returns since when a held file has been missing from every listing, or nil while it is listed.
  static func noteListing(_ key: ObjectKey, listed: Bool, of adopted: ReplicaID, by adopter: ReplicaID, now millis: Int64, in db: Database) throws -> Int64? {
    let arguments: StatementArguments = [adopter.description, adopted.description, key.rawValue]
    let sql = listed ? "UPDATE sync_adoption_fold SET unlisted = NULL" : "UPDATE sync_adoption_fold SET unlisted = COALESCE(unlisted, ?)"
    try db.execute(sql: sql + " WHERE adopter = ? AND adopted = ? AND object_key = ?", arguments: listed ? arguments : [millis] + arguments)
    let since = "SELECT unlisted FROM sync_adoption_fold WHERE adopter = ? AND adopted = ? AND object_key = ?"
    return try Int64?.fetchOne(db, sql: since, arguments: arguments) ?? nil
  }

  static func foldedKeys(of adopted: ReplicaID, by adopter: ReplicaID, in db: Database) throws -> Set<ObjectKey> {
    let rows = try String.fetchAll(
      db, sql: "SELECT object_key FROM sync_adoption_fold WHERE adopter = ? AND adopted = ?", arguments: [adopter.description, adopted.description])
    return Set(rows.compactMap(ObjectKey.init))
  }

  static func removeFolds(_ keys: [ObjectKey], of adopted: ReplicaID, by adopter: ReplicaID, in db: Database) throws {
    for key in keys {
      try db.execute(
        sql: "DELETE FROM sync_adoption_fold WHERE adopter = ? AND adopted = ? AND object_key = ?", arguments: [adopter.description, adopted.description, key.rawValue])
    }
  }

  /// Returns when a base of `adopted` was first seen with parts folded and parts missing, recording now if it never was.
  static func gapSeen(_ base: SyncBaseName, of adopted: ReplicaID, by adopter: ReplicaID, now millis: Int64, in db: Database) throws -> Int64 {
    let arguments: StatementArguments = [adopter.description, adopted.description, base.upTo, base.tag.description, base.parts]
    try db.execute(sql: "INSERT OR IGNORE INTO sync_adoption_gap (adopter, adopted, up_to, tag, parts, seen) VALUES (?, ?, ?, ?, ?, ?)", arguments: arguments + [millis])
    let sql = "SELECT seen FROM sync_adoption_gap WHERE adopter = ? AND adopted = ? AND up_to = ? AND tag = ? AND parts = ?"
    return try Int64.fetchOne(db, sql: sql, arguments: arguments) ?? millis
  }

  static func removeGap(_ base: SyncBaseName, of adopted: ReplicaID, by adopter: ReplicaID, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM sync_adoption_gap WHERE adopter = ? AND adopted = ? AND up_to = ? AND tag = ? AND parts = ?",
      arguments: [adopter.description, adopted.description, base.upTo, base.tag.description, base.parts])
  }

  static func hasRows(otherThan adopter: ReplicaID, in db: Database) throws -> Bool {
    try ["sync_adoption", "sync_adoption_fold", "sync_adoption_gap"].contains { table in
      try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \(table) WHERE adopter <> ?)", arguments: [adopter.description]) ?? false
    }
  }

  static func clear(otherThan adopter: ReplicaID, in db: Database) throws {
    for table in ["sync_adoption", "sync_adoption_fold", "sync_adoption_gap"] {
      try db.execute(sql: "DELETE FROM \(table) WHERE adopter <> ?", arguments: [adopter.description])
    }
  }

  static func clear(_ db: Database) throws {
    for table in ["sync_adoption", "sync_adoption_fold", "sync_adoption_gap"] { try db.execute(sql: "DELETE FROM \(table)") }
  }
}
