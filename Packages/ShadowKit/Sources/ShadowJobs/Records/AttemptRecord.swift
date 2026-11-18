import Foundation
import ShadowCore
import ShadowStore

public struct AttemptStart: Sendable, Hashable {
  public let job: EntityRef
  public let replica: ReplicaID
  public let started: LeaseInstant
  public let byHand: Bool
  /// What the attempt read when it started (plan revision, previous chapter, Story Bible hash), so later steps never read the live store for them.
  public let pinned: JSONValue

  public init(job: EntityRef, replica: ReplicaID, started: LeaseInstant, byHand: Bool, pinned: JSONValue) {
    self.job = job
    self.replica = replica
    self.started = started
    self.byHand = byHand
    self.pinned = pinned
  }

  var json: JSONValue {
    .object([
      AttemptStartMember.job.rawValue: .string(job.key.rawValue), AttemptStartMember.replica.rawValue: .string(replica.description),
      AttemptStartMember.started.rawValue: .int(started.millis), AttemptStartMember.clock.rawValue: .string(started.source.rawValue),
      AttemptStartMember.byHand.rawValue: .bool(byHand), AttemptStartMember.pinned.rawValue: pinned,
    ])
  }

  init(json: JSONValue) throws(StoredShapeError) {
    let members = try StoredMembers(json, shape: AttemptField.start.rawValue)
    let job = try members.value(AttemptStartMember.job.rawValue, EntityKey.init)
    let started = LeaseInstant(
      millis: try members.int(AttemptStartMember.started.rawValue), source: try members.value(AttemptStartMember.clock.rawValue, AttemptClockSource.init(rawValue:)))
    self.init(
      job: EntityRef(kind: JobSchema.jobKind, key: job), replica: try members.value(AttemptStartMember.replica.rawValue, ReplicaID.init), started: started,
      byHand: try members.bool(AttemptStartMember.byHand.rawValue), pinned: members.json(AttemptStartMember.pinned.rawValue))
  }
}

public struct AttemptLease: Sendable, Hashable {
  public let expires: Int64
  public let renewed: Int64
  public let clock: AttemptClockSource

  var json: JSONValue {
    .object([
      AttemptLeaseMember.expires.rawValue: .int(expires), AttemptLeaseMember.renewed.rawValue: .int(renewed),
      AttemptLeaseMember.clock.rawValue: .string(clock.rawValue),
    ])
  }

  init(expires: Int64, renewed: Int64, clock: AttemptClockSource) {
    self.expires = expires
    self.renewed = renewed
    self.clock = clock
  }

  init(json: JSONValue) throws(StoredShapeError) {
    let members = try StoredMembers(json, shape: AttemptField.lease.rawValue)
    self.init(
      expires: try members.int(AttemptLeaseMember.expires.rawValue), renewed: try members.int(AttemptLeaseMember.renewed.rawValue),
      clock: try members.value(AttemptLeaseMember.clock.rawValue, AttemptClockSource.init(rawValue:)))
  }
}

public struct AttemptStep: Sendable, Hashable {
  public let name: String
  public let index: Int

  public init(name: String, index: Int) {
    self.name = name
    self.index = index
  }

  var json: JSONValue {
    .object([AttemptStepMember.name.rawValue: .string(name), AttemptStepMember.index.rawValue: .int(Int64(index))])
  }

  init(json: JSONValue) throws(StoredShapeError) {
    let members = try StoredMembers(json, shape: AttemptField.step.rawValue)
    guard let index = Int(exactly: try members.int(AttemptStepMember.index.rawValue)) else { throw StoredShapeError(reason: "step.index is out of range") }
    self.init(name: try members.string(AttemptStepMember.name.rawValue), index: index)
  }
}

public struct AttemptFailure: Sendable, Hashable {
  /// apps/novel-forge-server/src/modules/jobs/job.service.ts:270 keeps the first 2000 UTF-16 units; a split pair loses its first half here.
  static let messageLimit = 2000

  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = String(message.utf16.prefix(Self.messageLimit)) ?? String(message.utf16.prefix(Self.messageLimit - 1)) ?? ""
  }

  public init(_ error: any Error) {
    guard let error = error as? any ShadowError else {
      self.init(code: "jobs.step_failed", message: error.localizedDescription)
      return
    }
    self.init(code: error.code, message: error.errorDescription ?? error.code)
  }

  var json: JSONValue {
    .object([AttemptErrorMember.code.rawValue: .string(code), AttemptErrorMember.message.rawValue: .string(message)])
  }

  init(json: JSONValue) throws(StoredShapeError) {
    let members = try StoredMembers(json, shape: AttemptField.error.rawValue)
    self.init(code: try members.string(AttemptErrorMember.code.rawValue), message: try members.string(AttemptErrorMember.message.rawValue))
  }
}

public enum AttemptErrorMember: String, CaseIterable, Sendable {
  case code
  case message
}

/// How an attempt ends; only `failed` carries an error, so an error is never written with any other outcome.
public enum AttemptSettlement: Sendable, Hashable {
  case succeeded
  case failed(AttemptFailure)
  case stoodDown
  /// Only for the job's cancel: every replica reads it as one. A run the system ended stays interrupted, never settled cancelled.
  case cancelled

  public var outcome: AttemptOutcome {
    switch self {
    case .succeeded: .succeeded
    case .failed: .failed
    case .stoodDown: .stoodDown
    case .cancelled: .cancelled
    }
  }
}

public struct AttemptRecord: Sendable, Hashable {
  public let id: AttemptID
  public let start: AttemptStart
  public let lease: AttemptLease?
  /// The step running, or the last one once the attempt ended.
  public let step: AttemptStep?
  public let calls: [UUID]
  public let outcome: AttemptOutcome
  public let error: AttemptFailure?

  public func isLive(at now: LeaseInstant) -> Bool {
    outcome == .running && lease?.isLive(at: now) == true
  }
}

public enum AttemptReading: Sendable, Hashable {
  case absent
  case unreadable(String)
  case readable(AttemptRecord)

  public var record: AttemptRecord? {
    guard case .readable(let record) = self else { return nil }
    return record
  }
}

/// `call` is appended to the cumulative `calls`.
public struct AttemptUpdate: Sendable, Hashable {
  public var lease: AttemptLease?
  public var step: AttemptStep?
  public var call: UUID?
  public var settlement: AttemptSettlement?

  public init(lease: AttemptLease? = nil, step: AttemptStep? = nil, call: UUID? = nil, settlement: AttemptSettlement? = nil) {
    self.lease = lease
    self.step = step
    self.call = call
    self.settlement = settlement
  }
}
