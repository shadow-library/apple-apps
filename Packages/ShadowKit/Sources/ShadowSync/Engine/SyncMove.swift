import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// A base of the moving replica at sequence 0: it holds the whole merged state, so it covers none of the replica's own segments, which start at 1 as for any new replica.
public struct SyncMoveBase: Sendable, Equatable {
  public let replica: ReplicaID
  public let point: StreamPoint
  public let parts: [SealedFile]
  public let frontier: [ReplicaID: HLCTimestamp]

  public var reference: BaseReference {
    guard let reference = BaseReference(upTo: point.last, tag: point.tag, parts: parts.count) else { preconditionFailure("a sealed base has 1...\(VaultPath.maximumParts) parts") }
    return reference
  }
}

/// A move re-mint, recorded in the transaction that makes it. `retired` is the replica it retired, which is not the move's origin when a re-mint of another
/// cause came in between.
public struct SyncMoveRemint: Sendable, Equatable {
  public let retired: ReplicaID
  public let successor: ReplicaID
  /// Replicas with a file held when the re-mint cleared the held files; pass them to `SyncEngine.sealMoveBase(for:partial:)`.
  public let partial: Set<ReplicaID>
}

enum SyncMoveKernelStep: Sendable, Equatable {
  case requeued
}

enum SyncMoveRole: String {
  case out
  case follow
}

enum SyncMoveSchema {
  static let migration = StoreMigration(identifier: "com.shadow.library.shadowsync.move.1") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_move_notice (
          vault TEXT PRIMARY KEY NOT NULL,
          notice BLOB,
          requeued INTEGER NOT NULL CHECK (requeued IN (0, 1)),
          ignored INTEGER NOT NULL CHECK (ignored IN (0, 1)),
          seen INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID;
        CREATE TABLE sync_move_remint (
          origin TEXT PRIMARY KEY NOT NULL,
          role TEXT NOT NULL CHECK (role IN ('out', 'follow')),
          retired TEXT NOT NULL,
          successor TEXT NOT NULL,
          partial TEXT NOT NULL
        ) STRICT, WITHOUT ROWID;
        """)
  }
}

/// The row is the vault's, not a replica's, so a re-mint of any other cause keeps uploads refused, after a restart too, until the database continues as a new
/// replica elsewhere or the user chooses to stay. It holds the sealed notice read here, or none when the move was followed from a notice read another way.
enum SyncMoveNoticeTable {
  struct Row: Sendable {
    let data: Data?
    let requeued: Bool
    let ignored: Bool
  }

  static func load(_ vault: VaultID, in db: Database) throws -> Row? {
    guard let row = try GRDB.Row.fetchOne(db, sql: "SELECT notice, requeued, ignored FROM sync_move_notice WHERE vault = ?", arguments: [vault.rawValue]) else {
      return nil
    }
    return Row(
      data: try row.decode(forColumn: "notice"), requeued: try row.decode(Int.self, forColumn: "requeued") == 1, ignored: try row.decode(Int.self, forColumn: "ignored") == 1)
  }

  static func notice(of vault: VaultID, keys: (KeyID) -> VaultKey?, in db: Database) throws -> VaultMoveNotice? {
    guard let row = try load(vault, in: db), !row.ignored, let data = row.data else { return nil }
    do {
      return try VaultMoveNoticeCodec.open(data, vault: vault, keys: keys)
    } catch {
      throw SyncError.corruptState("a saved move notice no longer opens")
    }
  }

  static func refusesUploads(_ vault: VaultID, in db: Database) throws -> Bool {
    try load(vault, in: db).map { !$0.ignored } ?? false
  }

  /// A notice other than the one recorded replaces it, ignored or not, and is followed afresh.
  static func save(_ data: Data, for vault: VaultID, at millis: Int64, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO sync_move_notice (vault, notice, requeued, ignored, seen) VALUES (?, ?, 0, 0, ?)
        ON CONFLICT (vault) DO UPDATE SET notice = excluded.notice, ignored = 0, requeued = CASE WHEN notice IS NULL OR notice IS excluded.notice THEN requeued ELSE 0 END, seen = excluded.seen
        """,
      arguments: [vault.rawValue, data, millis])
  }

  static func markRequeued(_ vault: VaultID, at millis: Int64, in db: Database) throws {
    try db.execute(
      sql: "INSERT INTO sync_move_notice (vault, notice, requeued, ignored, seen) VALUES (?, NULL, 1, 0, ?) ON CONFLICT (vault) DO UPDATE SET requeued = 1, ignored = 0",
      arguments: [vault.rawValue, millis])
  }

  static func ignore(_ vault: VaultID, in db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_move_notice WHERE vault = ? AND notice IS NULL", arguments: [vault.rawValue])
    try db.execute(sql: "UPDATE sync_move_notice SET ignored = 1 WHERE vault = ?", arguments: [vault.rawValue])
  }

  static func clear(_ db: Database) throws {
    try db.execute(sql: "DELETE FROM sync_move_notice")
  }
}

enum SyncMoveRemintTable {
  static func load(origin: ReplicaID, role: SyncMoveRole, in db: Database) throws -> SyncMoveRemint? {
    let sql = "SELECT retired, successor, partial FROM sync_move_remint WHERE origin = ? AND role = ?"
    guard let row = try Row.fetchOne(db, sql: sql, arguments: [origin.description, role.rawValue]) else { return nil }
    guard let retired = ReplicaID(try row.decode(String.self, forColumn: "retired")), let successor = ReplicaID(try row.decode(String.self, forColumn: "successor")) else {
      throw SyncError.corruptState("a recorded move re-mint names a malformed replica")
    }
    let listed = try row.decode(String.self, forColumn: "partial").split(separator: ",").map { ReplicaID(String($0)) }
    guard listed.allSatisfy({ $0 != nil }) else { throw SyncError.corruptState("a recorded move re-mint names a malformed replica") }
    return SyncMoveRemint(retired: retired, successor: successor, partial: Set(listed.compactMap(\.self)))
  }

  static func save(origin: ReplicaID, role: SyncMoveRole, _ remint: SyncMoveRemint, in db: Database) throws {
    try db.execute(
      sql: "INSERT INTO sync_move_remint (origin, role, retired, successor, partial) VALUES (?, ?, ?, ?, ?)",
      arguments: [
        origin.description, role.rawValue, remint.retired.description, remint.successor.description, remint.partial.map(\.description).sorted().joined(separator: ","),
      ])
  }
}

enum SyncMoveSealer {
  /// Refuses, before anything is sealed, a change stamped beyond `limit` and a kind the target may not hold. The frontier records the highest clock of each
  /// stamping replica, leaving out `partial` ones: with a file of theirs held, their records here need not be every one below that clock.
  static func seal(
    _ snapshot: OwnSnapshot, registry: SchemaRegistry, vault: VaultID, key: VaultKey, capabilities: StorageCapabilities, partBytes: Int, limit: HLCTimestamp,
    partial: Set<ReplicaID>
  ) throws(SyncError) -> SyncMoveBase {
    var frontier: [ReplicaID: HLCTimestamp] = [:]
    var admitted: Set<EntityKind> = []
    for line in snapshot.lines {
      guard let json = try? CanonicalJSON.decode(line), let record = try? ChangeRecord(json: json) else { continue }
      guard record.clock <= limit else { throw .clockAhead(record.clock) }
      if !partial.contains(record.clock.replica) { frontier[record.clock.replica] = max(frontier[record.clock.replica] ?? record.clock, record.clock) }
      guard admitted.insert(record.entity).inserted, let schema = registry[record.entity] else { continue }
      guard capabilities.classPolicy.admits(schema.syncClass) else { throw .syncClassRefused(kind: record.entity, syncClass: schema.syncClass) }
    }
    guard let header = BaseHeader(replica: snapshot.replica, upTo: 0, through: nil, schema: snapshot.schema), let file = BaseFile(header: header, lines: snapshot.lines) else {
      throw .corruptState("the merged state does not form a base")
    }
    let parts = try SyncBaseSealer.sealParts(file, vault: vault, key: key, partBytes: partBytes, limit: capabilities.maxObjectBytes)
    guard let tag = parts.first?.tag else { throw .corruptState("a sealed base has no parts") }
    return SyncMoveBase(replica: snapshot.replica, point: StreamPoint(last: 0, tag: tag), parts: parts, frontier: frontier)
  }
}
