import Foundation
import ShadowCore
import ShadowStore

/// Only the attempt's `start.replica` writes it, and never after it ended.
public enum AttemptRecords {
  public static func start(_ id: AttemptID, _ start: AttemptStart, step: AttemptStep?, in transaction: inout WriteTransaction) throws(JobRecordError) -> AttemptRecord {
    switch try JobRecords.read(start.job, in: transaction) {
    case .readable: break
    case .absent: throw .jobNotFound(start.job)
    case .unreadable(let reason): throw .jobUnreadable(start.job, reason)
    }
    guard try storing({ () throws(StoreError) in try transaction.state(of: id.ref) }) == nil else { throw .attemptExists(id.ref) }
    let lease = AttemptLease.granted(at: start.started)
    var fields: [String: JSONValue] = [
      AttemptField.start.rawValue: start.json, AttemptField.lease.rawValue: lease.json, AttemptField.outcome.rawValue: .string(AttemptOutcome.running.rawValue),
    ]
    if let step { fields[AttemptField.step.rawValue] = step.json }
    try storing { () throws(StoreError) in _ = try transaction.set(id.ref, fields) }
    return AttemptRecord(id: id, start: start, lease: lease, step: step, calls: [], outcome: .running, error: nil)
  }

  @discardableResult
  public static func update(_ id: AttemptID, _ update: AttemptUpdate, by writer: ReplicaID, in transaction: inout WriteTransaction) throws(JobRecordError) -> Bool {
    let record = try owned(id, by: writer, in: transaction)
    var fields: [String: JSONValue] = [:]
    if let lease = update.lease, record.lease.map({ lease.expires != $0.expires }) ?? true { fields[AttemptField.lease.rawValue] = lease.json }
    if let step = update.step, step != record.step { fields[AttemptField.step.rawValue] = step.json }
    if let call = update.call, !record.calls.contains(call) {
      fields[AttemptField.calls.rawValue] = .array((record.calls + [call]).map { .string(EntityKey(uuid: $0).rawValue) })
    }
    if let settlement = update.settlement {
      fields[AttemptField.outcome.rawValue] = .string(settlement.outcome.rawValue)
      if case .failed(let failure) = settlement { fields[AttemptField.error.rawValue] = failure.json }
    }
    guard !fields.isEmpty else { return false }
    try storing { () throws(StoreError) in _ = try transaction.set(id.ref, fields) }
    return true
  }

  /// For the transaction that opens a ledger call.
  @discardableResult
  public static func recordCall(_ call: UUID, attempt id: AttemptID, by writer: ReplicaID, in transaction: inout WriteTransaction) throws(JobRecordError) -> Bool {
    try update(id, AttemptUpdate(call: call), by: writer, in: &transaction)
  }

  public static func reading(_ state: EntityState?, of ref: EntityRef) -> AttemptReading {
    guard let state else { return .absent }
    guard case .record(let record) = state else { return .unreadable("it is not a record") }
    guard let start = record[field: AttemptField.start.rawValue] else { return .unreadable("its start has not arrived") }
    guard let uuid = UUID(uuidString: ref.key.rawValue), EntityKey(uuid: uuid) == ref.key, let id = try? AttemptID(uuid) else {
      return .unreadable("its key is not a version 7 UUID")
    }
    do {
      let outcome = try member(.outcome, of: record) { value throws(StoredShapeError) in
        guard let outcome = value.stringValue.flatMap(AttemptOutcome.init(rawValue:)) else { throw StoredShapeError(reason: "outcome is not a known value") }
        return outcome
      }
      return .readable(
        AttemptRecord(
          id: id, start: try AttemptStart(json: start.value), lease: try member(.lease, of: record, AttemptLease.init(json:)),
          step: try member(.step, of: record, AttemptStep.init(json:)), calls: try member(.calls, of: record, calls) ?? [], outcome: outcome ?? .running,
          error: try member(.error, of: record, AttemptFailure.init(json:))))
    } catch {
      return .unreadable(error.reason)
    }
  }

  public static func read(_ id: AttemptID, in transaction: ReadTransaction) throws(JobRecordError) -> AttemptReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: id.ref) }, of: id.ref)
  }

  public static func read(_ id: AttemptID, in transaction: borrowing WriteTransaction) throws(JobRecordError) -> AttemptReading {
    reading(try storing { () throws(StoreError) in try transaction.state(of: id.ref) }, of: id.ref)
  }

  private static func owned(_ id: AttemptID, by writer: ReplicaID, in transaction: borrowing WriteTransaction) throws(JobRecordError) -> AttemptRecord {
    let record: AttemptRecord
    switch try read(id, in: transaction) {
    case .absent: throw .attemptNotFound(id.ref)
    case .unreadable(let reason): throw .attemptUnreadable(id.ref, reason)
    case .readable(let readable): record = readable
    }
    guard record.start.replica == writer else { throw .notWriter(id.ref, owner: record.start.replica, writer: writer) }
    guard record.outcome == .running else { throw .attemptSettled(id.ref, record.outcome) }
    return record
  }

  private static func member<T>(_ field: AttemptField, of record: RecordState, _ decode: (JSONValue) throws(StoredShapeError) -> T) throws(StoredShapeError) -> T? {
    try record[field: field.rawValue].map { stored throws(StoredShapeError) in try decode(stored.value) }
  }

  private static func calls(_ value: JSONValue) throws(StoredShapeError) -> [UUID] {
    guard let items = value.arrayValue else { throw StoredShapeError(reason: "calls is not an array") }
    return try items.map { item throws(StoredShapeError) in
      guard let text = item.stringValue, let id = UUID(uuidString: text) else { throw StoredShapeError(reason: "calls holds an entry that is not a UUID") }
      return id
    }
  }
}
