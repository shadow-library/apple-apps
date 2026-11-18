import Foundation
import ShadowCore
import ShadowStore

public struct JobRequest: Sendable, Hashable {
  public let key: JobKey
  public let payload: JSONValue
  /// An object the requesting app owns, such as the chat card the job came from.
  public let origin: JSONValue
  public let replica: ReplicaID

  public init(key: JobKey, payload: JSONValue, origin: JSONValue = .null, replica: ReplicaID) {
    self.key = key
    self.payload = payload
    self.origin = origin
    self.replica = replica
  }

  var json: JSONValue {
    var members = key.requestMembers
    members[JobRequestMember.payload.rawValue] = payload
    members[JobRequestMember.origin.rawValue] = origin
    members[JobRequestMember.replica.rawValue] = .string(replica.description)
    return .object(members)
  }

  init(json: JSONValue, of ref: EntityRef) throws(StoredShapeError) {
    let key: JobKey
    do {
      key = try JobKey(request: json, of: ref)
    } catch {
      throw StoredShapeError(reason: error.errorDescription ?? error.code)
    }
    let members = try StoredMembers(json, shape: JobField.request.rawValue)
    self.init(
      key: key, payload: members.json(JobRequestMember.payload.rawValue), origin: members.json(JobRequestMember.origin.rawValue),
      replica: try members.value(JobRequestMember.replica.rawValue, ReplicaID.init))
  }
}

public struct JobRecord: Sendable, Hashable {
  public let request: JobRequest
  public let cancel: JobCancel

  public var ref: EntityRef { request.key.ref }
}

/// A job whose request has not arrived yet (only its cancel has) reads as `.unreadable`, and every reader skips it.
public enum JobReading: Sendable, Hashable {
  case absent
  case unreadable(String)
  case readable(JobRecord)

  public var record: JobRecord? {
    guard case .readable(let record) = self else { return nil }
    return record
  }
}

public enum JobRequestOutcome: Sendable, Hashable {
  case requested(JobRecord)
  case existing(JobRecord)

  public var job: JobRecord {
    switch self {
    case .requested(let job), .existing(let job): job
    }
  }
}

public enum JobCancelOutcome: String, Sendable, Hashable {
  case requested
  case alreadyRequested
  case alreadySucceeded
}

public enum JobRecords {
  /// A second request of the key writes nothing and answers the job as stored.
  public static func request(_ request: JobRequest, in transaction: inout WriteTransaction) throws(JobRecordError) -> JobRequestOutcome {
    let ref = request.key.ref
    let state = try storing { () throws(StoreError) in try transaction.state(of: ref) }
    var cancel: JobCancel?
    switch reading(state, of: ref) {
    case .readable(let job):
      return .existing(job)
    case .unreadable(let reason):
      guard case .record(let record)? = state, record[field: JobField.request.rawValue] == nil else { throw .jobUnreadable(ref, reason) }
      cancel = record[field: JobField.cancel.rawValue]?.value.stringValue.flatMap(JobCancel.init(rawValue:))
    case .absent:
      break
    }
    var fields: [String: JSONValue] = [JobField.request.rawValue: request.json]
    if cancel == nil { fields[JobField.cancel.rawValue] = .string(JobCancel.none.rawValue) }
    try storing { () throws(StoreError) in _ = try transaction.set(ref, fields) }
    return .requested(JobRecord(request: request, cancel: cancel ?? .none))
  }

  /// A succeeded job keeps its outputs (apps/novel-forge-server/src/modules/jobs/job.service.ts:351-355).
  public static func cancel(_ ref: EntityRef, in transaction: inout WriteTransaction) throws(JobRecordError) -> JobCancelOutcome {
    guard let snapshot = try JobSnapshot.load(ref, in: transaction) else { throw .jobNotFound(ref) }
    if snapshot.attempts.contains(where: { $0.outcome == .succeeded }) { return .alreadySucceeded }
    if snapshot.job.cancel == .requested { return .alreadyRequested }
    try storing { () throws(StoreError) in _ = try transaction.set(ref, [JobField.cancel.rawValue: .string(JobCancel.requested.rawValue)]) }
    return .requested
  }

  public static func reading(_ state: EntityState?, of ref: EntityRef) -> JobReading {
    guard let state, case .record(let record) = state else { return state.map { _ in .unreadable("it is not a record") } ?? .absent }
    guard let request = record[field: JobField.request.rawValue] else { return .unreadable("its request has not arrived") }
    do {
      let cancel = try record[field: JobField.cancel.rawValue].map { field throws(StoredShapeError) in
        guard let cancel = field.value.stringValue.flatMap(JobCancel.init(rawValue:)) else { throw StoredShapeError(reason: "cancel is not a known value") }
        return cancel
      }
      return .readable(JobRecord(request: try JobRequest(json: request.value, of: ref), cancel: cancel ?? .none))
    } catch {
      return .unreadable(error.reason)
    }
  }

  public static func read(_ ref: EntityRef, in transaction: ReadTransaction) throws(JobRecordError) -> JobReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: ref) }, of: ref)
  }

  public static func read(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(JobRecordError) -> JobReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: ref) }, of: ref)
  }
}

func storing<T>(_ body: () throws(StoreError) -> T) throws(JobRecordError) -> T {
  do {
    return try body()
  } catch {
    throw .store(error)
  }
}
