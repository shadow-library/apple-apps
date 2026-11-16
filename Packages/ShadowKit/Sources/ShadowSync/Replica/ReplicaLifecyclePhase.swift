import Foundation
import GRDB
import ShadowCore
import ShadowStore

/// `token` is the value the device marker holds for an unfinished re-mint; a marker naming anything else means the database left this device mid-way.
enum ReplicaLifecyclePhase: Sendable, Equatable {
  case fresh
  case claiming(replica: ReplicaID, previous: ReplicaID?)
  case claimed(ReplicaID)
  case preparing(replica: ReplicaID, retiring: ReplicaID, token: ReplicaID, reason: RemintReason)
  case moving(replica: ReplicaID, retiring: ReplicaID, token: ReplicaID, reason: RemintReason)

  static let migration = StoreMigration(identifier: "shadow.sync.lifecycle.1") { db in
    try db.execute(
      sql: """
        CREATE TABLE sync_replica_lifecycle (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          phase TEXT NOT NULL CHECK (phase IN ('fresh', 'claiming', 'claimed', 'preparing', 'moving')),
          replica TEXT,
          previous TEXT,
          retiring TEXT,
          token TEXT,
          reason TEXT
        ) STRICT;
        INSERT INTO sync_replica_lifecycle (id, phase) VALUES (1, 'fresh');
        """)
  }

  var replica: ReplicaID? {
    switch self {
    case .fresh: nil
    case .claiming(let replica, _), .claimed(let replica), .preparing(let replica, _, _, _), .moving(let replica, _, _, _): replica
    }
  }

  static func load(_ db: Database) throws -> ReplicaLifecyclePhase {
    guard let row = try Row.fetchOne(db, sql: "SELECT phase, replica, previous, retiring, token, reason FROM sync_replica_lifecycle WHERE id = 1") else {
      throw ReplicaLifecycleError.corruptState("the lifecycle row is missing")
    }
    let phase: String = try row.decode(forColumn: "phase")
    if phase == "fresh" { return .fresh }
    guard let replica = try replicaColumn(row, "replica") else { throw ReplicaLifecycleError.corruptState("the \(phase) phase names no replica") }
    switch phase {
    case "claiming":
      return .claiming(replica: replica, previous: try replicaColumn(row, "previous"))
    case "claimed":
      return .claimed(replica)
    case "preparing", "moving":
      let text: String? = try row.decode(forColumn: "reason")
      guard let retiring = try replicaColumn(row, "retiring"), let token = try replicaColumn(row, "token"), let reason = text.flatMap(RemintReason.init(stored:)) else {
        throw ReplicaLifecycleError.corruptState("the \(phase) phase is incomplete")
      }
      return phase == "moving"
        ? .moving(replica: replica, retiring: retiring, token: token, reason: reason) : .preparing(replica: replica, retiring: retiring, token: token, reason: reason)
    default:
      throw ReplicaLifecycleError.corruptState("the lifecycle phase is unknown")
    }
  }

  func save(_ db: Database) throws {
    let columns: (phase: String, replica: ReplicaID?, previous: ReplicaID?, retiring: ReplicaID?, token: ReplicaID?, reason: String?) =
      switch self {
      case .fresh: ("fresh", nil, nil, nil, nil, nil)
      case .claiming(let replica, let previous): ("claiming", replica, previous, nil, nil, nil)
      case .claimed(let replica): ("claimed", replica, nil, nil, nil, nil)
      case .preparing(let replica, let retiring, let token, let reason): ("preparing", replica, nil, retiring, token, reason.stored)
      case .moving(let replica, let retiring, let token, let reason): ("moving", replica, nil, retiring, token, reason.stored)
      }
    try db.execute(
      sql: "UPDATE sync_replica_lifecycle SET phase = ?, replica = ?, previous = ?, retiring = ?, token = ?, reason = ? WHERE id = 1",
      arguments: [columns.phase, columns.replica?.description, columns.previous?.description, columns.retiring?.description, columns.token?.description, columns.reason])
    guard db.changesCount == 1 else { throw ReplicaLifecycleError.corruptState("the lifecycle row is missing") }
  }

  private static func replicaColumn(_ row: Row, _ column: String) throws -> ReplicaID? {
    let text: String? = try row.decode(forColumn: column)
    guard let text else { return nil }
    guard let replica = ReplicaID(text) else { throw ReplicaLifecycleError.corruptState("\(column) is not a replica id") }
    return replica
  }
}

extension RemintReason {
  var stored: String {
    let members: [String: JSONValue] =
      switch self {
      case .markerMissing: ["kind": "marker-missing"]
      case .markerNamesOther(let replica): ["kind": "marker-other", "replica": .string(replica.description)]
      case .retired: ["kind": "retired"]
      case .unknownSegment(let point): ["kind": "unknown-segment", "last": .int(point.last), "tag": .string(point.tag.description)]
      case .unknownBase(let point): ["kind": "unknown-base", "last": .int(point.last), "tag": .string(point.tag.description)]
      case .unknownObject(let key): ["kind": "unknown-object", "key": .string(key.rawValue)]
      }
    return String(decoding: CanonicalJSON.encode(.object(members)), as: UTF8.self)
  }

  init?(stored: String) {
    guard let value = try? CanonicalJSON.decode(Data(stored.utf8)), let members = value.objectValue, let kind = members["kind"]?.stringValue else { return nil }
    let point = members["last"]?.intValue.flatMap { last in members["tag"]?.stringValue.flatMap(ContentTag.init).map { StreamPoint(last: last, tag: $0) } }
    switch kind {
    case "marker-missing": self = .markerMissing
    case "retired": self = .retired
    case "marker-other":
      guard let replica = members["replica"]?.stringValue.flatMap(ReplicaID.init) else { return nil }
      self = .markerNamesOther(replica)
    case "unknown-segment":
      guard let point else { return nil }
      self = .unknownSegment(point)
    case "unknown-base":
      guard let point else { return nil }
      self = .unknownBase(point)
    case "unknown-object":
      guard let key = members["key"]?.stringValue.flatMap(ObjectKey.init) else { return nil }
      self = .unknownObject(key)
    default: return nil
    }
  }
}
