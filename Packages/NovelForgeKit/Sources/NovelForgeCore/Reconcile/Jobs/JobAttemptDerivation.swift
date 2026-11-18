import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// A readable attempt; one that cannot be read yet is left out, as `JobSnapshot` leaves it out.
public struct JobAttemptRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_job_attempt"

  public let attempt: AttemptID
  public let job: EntityKey
  public let replica: ReplicaID
  public let started: LeaseInstant
  public let byHand: Bool
  public let leaseExpires: Int64?
  public let leaseRenewed: Int64?
  public let step: AttemptStep?
  public let outcome: AttemptOutcome
  public let error: AttemptFailure?
  public let calls: Int

  init(_ record: AttemptRecord) {
    self.init(
      attempt: record.id, job: record.start.job.key, replica: record.start.replica, started: record.start.started, byHand: record.start.byHand,
      leaseExpires: record.lease?.expires, leaseRenewed: record.lease?.renewed, step: record.step, outcome: record.outcome, error: record.error,
      calls: Set(record.calls).count)
  }

  init(
    attempt: AttemptID, job: EntityKey, replica: ReplicaID, started: LeaseInstant, byHand: Bool, leaseExpires: Int64?, leaseRenewed: Int64?, step: AttemptStep?,
    outcome: AttemptOutcome, error: AttemptFailure?, calls: Int
  ) {
    self.attempt = attempt
    self.job = job
    self.replica = replica
    self.started = started
    self.byHand = byHand
    self.leaseExpires = leaseExpires
    self.leaseRenewed = leaseRenewed
    self.step = step
    self.outcome = outcome
    self.error = error
    self.calls = calls
  }

  public init(row: Row) throws {
    let stepName = try row.decode(String?.self, forColumn: "step")
    let stepIndex = try row.decode(Int?.self, forColumn: "step_index")
    let errorCode = try row.decode(String?.self, forColumn: "error_code")
    let errorMessage = try row.decode(String?.self, forColumn: "error_message")
    self.init(
      attempt: try JobColumns.attempt(try row.decode(String.self, forColumn: "attempt")), job: try JobColumns.key(try row.decode(String.self, forColumn: "job")),
      replica: try JobColumns.replica(try row.decode(String.self, forColumn: "replica")),
      started: LeaseInstant(
        millis: try row.decode(Int64.self, forColumn: "started"),
        source: try JobColumns.value(try row.decode(String.self, forColumn: "clock"), AttemptClockSource.self)),
      byHand: try row.decode(Bool.self, forColumn: "by_hand"), leaseExpires: try row.decode(Int64?.self, forColumn: "lease_expires"),
      leaseRenewed: try row.decode(Int64?.self, forColumn: "lease_renewed"),
      step: stepName.flatMap { name in stepIndex.map { AttemptStep(name: name, index: $0) } },
      outcome: try JobColumns.value(try row.decode(String.self, forColumn: "outcome"), AttemptOutcome.self),
      error: errorCode.flatMap { code in errorMessage.map { AttemptFailure(code: code, message: $0) } }, calls: try row.decode(Int.self, forColumn: "calls"))
  }

  public var ref: EntityRef { attempt.ref }

  public var jobRef: EntityRef { JobColumns.jobRef(job) }

  /// `AttemptRecord.isLive(at:)` from the stored lease.
  public func isLive(at now: LeaseInstant) -> Bool {
    outcome == .running && leaseExpires.map { AttemptLease.isLive(expires: $0, at: now) } == true
  }

  /// `AttemptRecord.outranks(_:)`: the earlier start, then the lower id.
  func outranks(_ other: JobAttemptRow) -> Bool {
    guard started.millis == other.started.millis else { return started.millis < other.started.millis }
    return attempt.uuid.lowercasedString.utf8.lexicographicallyPrecedes(other.attempt.uuid.lowercasedString.utf8)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["attempt"] = attempt.uuid.lowercasedString
    container["job"] = job.rawValue
    container["replica"] = replica.description
    container["started"] = started.millis
    container["clock"] = started.source.rawValue
    container["by_hand"] = byHand
    container["lease_expires"] = leaseExpires
    container["lease_renewed"] = leaseRenewed
    container["step"] = step?.name
    container["step_index"] = step?.index
    container["outcome"] = outcome.rawValue
    container["error_code"] = error?.code
    container["error_message"] = error?.message
    container["calls"] = calls
  }
}

public struct JobAttemptDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_job_attempt (
      attempt TEXT PRIMARY KEY, job TEXT NOT NULL, replica TEXT NOT NULL, started INTEGER NOT NULL, clock TEXT NOT NULL, by_hand INTEGER NOT NULL,
      lease_expires INTEGER, lease_renewed INTEGER, step TEXT, step_index INTEGER, outcome TEXT NOT NULL, error_code TEXT, error_message TEXT, calls INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_job_attempt_job ON nf_derived_job_attempt (job);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.kit([JobSchema.attemptKind]) { [$0] }]
  }

  public static func key(of output: JobAttemptRow) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<JobAttemptRow> {
    guard let id = JobColumns.uuid(of: ref, JobSchema.attemptKind) else { return JobAttemptRow.filter(sql: "0") }
    return JobAttemptRow.filter(Column("attempt") == id.lowercasedString)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(ofKit: JobSchema.attemptKind))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [JobAttemptRow] {
    guard ref.kind == JobSchema.attemptKind, let record = AttemptRecords.reading(try context.records.state(of: ref, scope: .vault), of: ref).record else { return [] }
    return [JobAttemptRow(record)]
  }
}

enum JobLease {
  private static let window = millis(LeaseTerms.duration + LeaseTerms.skew)

  /// The next instant after `now` at which `AttemptLease.isLive(expires:at:)` changes for this lease, if any.
  static func change(expires: Int64, after now: LeaseInstant) -> Int64? {
    let opens = expires - window
    if now.millis < opens { return opens }
    return now.millis < expires ? expires : nil
  }

  private static func millis(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
}
