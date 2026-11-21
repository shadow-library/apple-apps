import Foundation
import ShadowCore
import ShadowStore

/// The vault's worker setting: a hint that the named replica starts the vault's queued attempts. Replicas that disagree for a moment are tolerated.
public struct WorkerRecord: Sendable, Hashable {
  public let replica: ReplicaID?
  public let since: LeaseInstant

  public init(replica: ReplicaID?, since: LeaseInstant) {
    self.replica = replica
    self.since = since
  }

  var fields: [String: JSONValue] {
    [
      WorkerField.replica.rawValue: replica.map { .string($0.description) } ?? .null,
      WorkerField.since.rawValue: .object([WorkerSinceMember.millis.rawValue: .int(since.millis), WorkerSinceMember.clock.rawValue: .string(since.source.rawValue)]),
    ]
  }

  init(record: RecordState) throws(StoredShapeError) {
    guard let replica = record[field: WorkerField.replica.rawValue], let since = record[field: WorkerField.since.rawValue] else {
      throw StoredShapeError(reason: "its replica or since has not arrived")
    }
    let members = try StoredMembers(since.value, shape: WorkerField.since.rawValue)
    let instant = LeaseInstant(
      millis: try members.int(WorkerSinceMember.millis.rawValue), source: try members.value(WorkerSinceMember.clock.rawValue, AttemptClockSource.init(rawValue:)))
    switch replica.value {
    case .null:
      self.init(replica: nil, since: instant)
    case .string(let text):
      guard let id = ReplicaID(text) else { throw StoredShapeError(reason: "replica is not a replica id") }
      self.init(replica: id, since: instant)
    default:
      throw StoredShapeError(reason: "replica is neither a replica id nor null")
    }
  }
}

public enum WorkerReading: Sendable, Hashable {
  case absent
  case unreadable(String)
  case readable(WorkerRecord)

  public var record: WorkerRecord? {
    guard case .readable(let record) = self else { return nil }
    return record
  }
}

/// One record per vault; the later write wins on every replica.
public enum WorkerRecords {
  public static let domain = ShadowJobs.identifier + ".worker"
  public static let ref = EntityRef(kind: JobSchema.workerKind, key: .natural(scope: domain, kind: JobSchema.workerKind, components: []))

  /// Naming the replica already named writes nothing and keeps its `since`; nil names none. An unreadable record is overwritten.
  @discardableResult
  public static func designate(_ replica: ReplicaID?, at since: LeaseInstant, in transaction: inout WriteTransaction) throws(JobRecordError) -> WorkerRecord {
    if let current = try read(in: transaction).record, current.replica == replica { return current }
    let record = WorkerRecord(replica: replica, since: since)
    try storing { () throws(StoreError) in _ = try transaction.set(ref, record.fields) }
    return record
  }

  public static func reading(_ state: EntityState?) -> WorkerReading {
    guard let state else { return .absent }
    guard case .record(let record) = state else { return .unreadable("it is not a record") }
    do {
      return .readable(try WorkerRecord(record: record))
    } catch {
      return .unreadable(error.reason)
    }
  }

  public static func read(in transaction: ReadTransaction) throws(JobRecordError) -> WorkerReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: ref) })
  }

  public static func read(in transaction: borrowing WriteTransaction) throws(JobRecordError) -> WorkerReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: ref) })
  }
}
