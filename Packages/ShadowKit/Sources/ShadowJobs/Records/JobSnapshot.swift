import Foundation
import ShadowCore
import ShadowStore

/// An attempt that cannot be read yet is left out.
public struct JobSnapshot: Sendable, Hashable {
  public let job: JobRecord
  public let attempts: [AttemptRecord]

  public init(job: JobRecord, attempts: [AttemptRecord]) {
    self.job = job
    self.attempts = attempts.filter { $0.start.job == job.ref }.sorted { $0.outranks($1) }
  }

  /// Nil until the job's request is readable, so every reader skips the job (snapshot cost grows with all attempts; G17's tables index it).
  public static func load(_ ref: EntityRef, in transaction: ReadTransaction) throws(JobRecordError) -> JobSnapshot? {
    try load(ref, from: transaction)
  }

  public static func load(_ ref: EntityRef, in transaction: borrowing WriteTransaction) throws(JobRecordError) -> JobSnapshot? {
    try load(ref, from: transaction)
  }

  private static func load<Reader: JobStateReader & ~Copyable>(_ ref: EntityRef, from reader: borrowing Reader) throws(JobRecordError) -> JobSnapshot? {
    guard let job = JobRecords.reading(try storing { () throws(StoreError) in try reader.state(of: ref, scope: .vault) }, of: ref).record else { return nil }
    let keys = try storing { () throws(StoreError) in try reader.attemptStarts() }.compactMap { key, start in
      start[AttemptStartMember.job.rawValue]?.stringValue == ref.key.rawValue ? key : nil
    }
    var attempts: [AttemptRecord] = []
    for key in keys {
      let attempt = EntityRef(kind: JobSchema.attemptKind, key: key)
      if let record = AttemptRecords.reading(try storing { () throws(StoreError) in try reader.state(of: attempt, scope: .vault) }, of: attempt).record {
        attempts.append(record)
      }
    }
    return JobSnapshot(job: job, attempts: attempts)
  }
}

extension AttemptRecord {
  /// The earlier start outranks, then the lower id.
  public func outranks(_ other: AttemptRecord) -> Bool {
    guard start.started.millis == other.start.started.millis else { return start.started.millis < other.start.started.millis }
    return id.uuid.lowercasedString.utf8.lexicographicallyPrecedes(other.id.uuid.lowercasedString.utf8)
  }
}

protocol JobStateReader: ~Copyable {
  func state(of ref: EntityRef, scope: StateScope) throws(StoreError) -> EntityState?
  func attemptStarts() throws(StoreError) -> [EntityKey: JSONValue]
}

extension ReadTransaction: JobStateReader {
  func attemptStarts() throws(StoreError) -> [EntityKey: JSONValue] {
    try fieldValues(ofKind: JobSchema.attemptKind, named: [AttemptField.start.rawValue]).compactMapValues { $0[AttemptField.start.rawValue] }
  }
}

extension WriteTransaction: JobStateReader {
  func attemptStarts() throws(StoreError) -> [EntityKey: JSONValue] {
    var starts: [EntityKey: JSONValue] = [:]
    for (ref, state) in try states(ofKind: JobSchema.attemptKind) {
      if case .record(let record) = state, let start = record[field: AttemptField.start.rawValue] { starts[ref.key] = start.value }
    }
    return starts
  }
}
