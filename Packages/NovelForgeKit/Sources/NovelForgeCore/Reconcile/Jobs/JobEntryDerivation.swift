import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

enum JobEnd: Hashable, Sendable {
  case succeeded(AttemptID)
  case cancelled
}

/// What a job reads as once no attempt holds a live lease.
public enum JobFallback: String, Sendable, DatabaseValueConvertible {
  case queued
  case failed
}

/// A running attempt's lease; whether it is live is decided when the job is read, against that moment.
public struct JobLeaseHolder: Hashable, Sendable {
  public let attempt: AttemptID
  public let expires: Int64
  public let replica: ReplicaID
  public let step: AttemptStep?
  public let renewed: Int64

  public var expiry: Date { Date(timeIntervalSince1970: Double(expires) / 1000) }

  public var renewal: Date { Date(timeIntervalSince1970: Double(renewed) / 1000) }

  public func isLive(at now: LeaseInstant) -> Bool { AttemptLease.isLive(expires: expires, at: now) }
}

extension [JobLeaseHolder] {
  /// The first holder in rank order whose lease is live, as `JobStatus` picks the running attempt.
  func live(at now: LeaseInstant) -> JobLeaseHolder? { first { $0.isLive(at: now) } }

  /// The next instant after `now` at which some holder's liveness changes with no write in between.
  func nextChange(after now: LeaseInstant) -> Int64? { compactMap { JobLease.change(expires: $0.expires, after: now) }.min() }
}

/// Everything `JobStatus` reads, kept in rank order so it can be decided at any `now` without the attempts.
struct JobStanding: Hashable, Sendable {
  let end: JobEnd?
  let fallback: JobFallback
  let failed: AttemptID?
  let failure: AttemptFailure?
  let holders: [JobLeaseHolder]

  /// As `JobStatus.init(_:at:)` ranks: a success, then a cancel, then a live lease, then the latest attempt that did not stand down.
  init(cancel: JobCancel, attempts ranked: [JobAttemptRow]) {
    if let succeeded = ranked.first(where: { $0.outcome == .succeeded }) {
      end = .succeeded(succeeded.attempt)
    } else if cancel == .requested || ranked.contains(where: { $0.outcome == .cancelled }) {
      end = .cancelled
    } else {
      end = nil
    }
    let latest = ranked.last { $0.outcome != .stoodDown }
    let failed = latest?.outcome == .failed ? latest : nil
    fallback = failed == nil ? .queued : .failed
    self.failed = failed?.attempt
    failure = failed?.error
    holders = ranked.compactMap { row in
      guard row.outcome == .running, let expires = row.leaseExpires, let renewed = row.leaseRenewed else { return nil }
      return JobLeaseHolder(attempt: row.attempt, expires: expires, replica: row.replica, step: row.step, renewed: renewed)
    }
  }

  init(end: JobEnd?, fallback: JobFallback, failed: AttemptID?, failure: AttemptFailure?, holders: [JobLeaseHolder]) {
    self.end = end
    self.fallback = fallback
    self.failed = failed
    self.failure = failure
    self.holders = holders
  }

  /// Open while some `now` reads it queued or running.
  var isOpen: Bool { end == nil && (fallback == .queued || !holders.isEmpty) }

  func status(at now: LeaseInstant) -> JobStatus {
    switch end {
    case .succeeded(let attempt): return .succeeded(attempt)
    case .cancelled: return .cancelled
    case nil: break
    }
    if let live = holder(at: now) { return .running(live.attempt) }
    guard fallback == .failed, let failed else { return .queued }
    return .failed(failed, failure)
  }

  func holder(at now: LeaseInstant) -> JobLeaseHolder? {
    end == nil ? holders.live(at: now) : nil
  }

  func changes(after now: LeaseInstant) -> Int64? {
    end == nil ? holders.nextChange(after: now) : nil
  }

  static func encode(_ holders: [JobLeaseHolder]) -> String {
    let items: [JSONValue] = holders.map { holder in
      .object([
        "attempt": .string(holder.attempt.uuid.lowercasedString), "expires": .int(holder.expires), "renewed": .int(holder.renewed),
        "replica": .string(holder.replica.description), "step": holder.step.map { .string($0.name) } ?? .null,
        "index": holder.step.map { .int(Int64($0.index)) } ?? .null,
      ])
    }
    return String(decoding: CanonicalJSON.encode(.array(items)), as: UTF8.self)
  }

  static func decode(_ text: String) throws(StoreError) -> [JobLeaseHolder] {
    guard let items = (try? CanonicalJSON.decode(Data(text.utf8)))?.arrayValue else { throw .corruptStore("a job row holds unreadable lease holders") }
    return try items.map { item throws(StoreError) in
      guard let members = item.objectValue, let attempt = members["attempt"]?.stringValue, let expires = members["expires"]?.intValue,
        let renewed = members["renewed"]?.intValue, let replica = members["replica"]?.stringValue
      else { throw .corruptStore("a job row holds an incomplete lease holder") }
      let step = members["step"]?.stringValue.flatMap { name in members["index"]?.intValue.flatMap(Int.init(exactly:)).map { AttemptStep(name: name, index: $0) } }
      return JobLeaseHolder(attempt: try JobColumns.attempt(attempt), expires: expires, replica: try JobColumns.replica(replica), step: step, renewed: renewed)
    }
  }
}

/// A job whose request is readable; one whose request has not arrived, or cannot be read, is left out, as `JobSnapshot.load` leaves it out.
public struct JobEntry: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_job"

  public let job: EntityKey
  /// From the request's scope; nil for a job no novel owns.
  public let novel: UUID?
  /// From the request's target; nil for a job that targets no chapter.
  public let chapter: Int?
  public let kind: String
  public let target: String
  public let fingerprint: String
  public let run: Int
  /// The clock of the request that won.
  public let requested: HLCTimestamp
  public let requester: ReplicaID
  public let cancel: JobCancel
  public let attempts: Int
  /// The attempt that started last, as rank orders them.
  public let latest: JobLatestAttempt?
  let standing: JobStanding

  init(
    job: EntityKey, novel: UUID?, chapter: Int?, kind: String, target: String, fingerprint: String, run: Int, requested: HLCTimestamp, requester: ReplicaID,
    cancel: JobCancel, attempts: Int, latest: JobLatestAttempt?, standing: JobStanding
  ) {
    self.job = job
    self.novel = novel
    self.chapter = chapter
    self.kind = kind
    self.target = target
    self.fingerprint = fingerprint
    self.run = run
    self.requested = requested
    self.requester = requester
    self.cancel = cancel
    self.attempts = attempts
    self.latest = latest
    self.standing = standing
  }

  public init(row: Row) throws {
    var latest: JobLatestAttempt?
    if let attempt = try row.decode(String?.self, forColumn: "latest_attempt") {
      let stepName = try row.decode(String?.self, forColumn: "latest_step")
      let stepIndex = try row.decode(Int?.self, forColumn: "latest_step_index")
      latest = JobLatestAttempt(
        attempt: try JobColumns.attempt(attempt), replica: try JobColumns.replica(try row.decode(String.self, forColumn: "latest_replica")),
        leaseExpires: try row.decode(Int64?.self, forColumn: "latest_expires"), leaseRenewed: try row.decode(Int64?.self, forColumn: "latest_renewed"),
        step: stepName.flatMap { name in stepIndex.map { AttemptStep(name: name, index: $0) } },
        outcome: try JobColumns.value(try row.decode(String.self, forColumn: "latest_outcome"), AttemptOutcome.self))
    }
    let failedCode = try row.decode(String?.self, forColumn: "failed_code")
    let failedMessage = try row.decode(String?.self, forColumn: "failed_message")
    let end: JobEnd? =
      switch try row.decode(String?.self, forColumn: "ended") {
      case nil: nil
      case "cancelled": .cancelled
      case "succeeded": .succeeded(try JobColumns.attempt(try row.decode(String.self, forColumn: "succeeded_attempt")))
      case let other?: throw StoreError.corruptStore("a job row holds an unknown end \(other)")
      }
    let standing = JobStanding(
      end: end,
      fallback: try row.decode(JobFallback.self, forColumn: "fallback"),
      failed: try row.decode(String?.self, forColumn: "failed_attempt").map { text throws(StoreError) in try JobColumns.attempt(text) },
      failure: failedCode.flatMap { code in failedMessage.map { AttemptFailure(code: code, message: $0) } },
      holders: try JobStanding.decode(try row.decode(String.self, forColumn: "holders")))
    self.init(
      job: try JobColumns.key(try row.decode(String.self, forColumn: "job")), novel: try row.decode(UUID?.self, forColumn: "novel"),
      chapter: try row.decode(Int?.self, forColumn: "chapter"), kind: try row.decode(String.self, forColumn: "kind"),
      target: try row.decode(String.self, forColumn: "target"), fingerprint: try row.decode(String.self, forColumn: "fingerprint"),
      run: try row.decode(Int.self, forColumn: "run"), requested: try JobColumns.clock(try row.decode(String.self, forColumn: "requested")),
      requester: try JobColumns.replica(try row.decode(String.self, forColumn: "requester")),
      cancel: try JobColumns.value(try row.decode(String.self, forColumn: "cancel"), JobCancel.self), attempts: try row.decode(Int.self, forColumn: "attempts"),
      latest: latest, standing: standing)
  }

  public var ref: EntityRef { JobColumns.jobRef(job) }

  public var jobKind: StoredEnum<NovelJobKind> { StoredEnum(rawValue: kind) }

  /// `JobStatus(snapshot, at: now)` without loading the attempts.
  public func status(at now: LeaseInstant) -> JobStatus { standing.status(at: now) }

  public func encode(to container: inout PersistenceContainer) throws {
    container["job"] = job.rawValue
    container["novel"] = novel
    container["chapter"] = chapter
    container["kind"] = kind
    container["target"] = target
    container["fingerprint"] = fingerprint
    container["run"] = run
    container["requested"] = requested.description
    container["requester"] = requester.description
    container["cancel"] = cancel.rawValue
    container["attempts"] = attempts
    container["latest_attempt"] = latest?.attempt.uuid.lowercasedString
    container["latest_replica"] = latest?.replica.description
    container["latest_expires"] = latest?.leaseExpires
    container["latest_renewed"] = latest?.leaseRenewed
    container["latest_step"] = latest?.step?.name
    container["latest_step_index"] = latest?.step?.index
    container["latest_outcome"] = latest?.outcome.rawValue
    switch standing.end {
    case .succeeded(let attempt):
      container["ended"] = "succeeded"
      container["succeeded_attempt"] = attempt.uuid.lowercasedString
    case .cancelled:
      container["ended"] = "cancelled"
      container["succeeded_attempt"] = nil
    case nil:
      container["ended"] = nil
      container["succeeded_attempt"] = nil
    }
    container["fallback"] = standing.fallback
    container["failed_attempt"] = standing.failed?.uuid.lowercasedString
    container["failed_code"] = standing.failure?.code
    container["failed_message"] = standing.failure?.message
    container["holders"] = JobStanding.encode(standing.holders)
  }
}

public struct JobLatestAttempt: Hashable, Sendable {
  public let attempt: AttemptID
  public let replica: ReplicaID
  public let leaseExpires: Int64?
  /// When its replica last wrote the lease; whether that lease is still live is read against a moment, never stored.
  public let leaseRenewed: Int64?
  public let step: AttemptStep?
  public let outcome: AttemptOutcome

  public var renewal: Date? { leaseRenewed.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
}

public struct JobEntryDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_job (
      job TEXT PRIMARY KEY, novel BLOB, chapter INTEGER, kind TEXT NOT NULL, target TEXT NOT NULL, fingerprint TEXT NOT NULL, run INTEGER NOT NULL,
      requested TEXT NOT NULL, requester TEXT NOT NULL, cancel TEXT NOT NULL, attempts INTEGER NOT NULL, latest_attempt TEXT, latest_replica TEXT,
      latest_expires INTEGER, latest_renewed INTEGER, latest_step TEXT, latest_step_index INTEGER, latest_outcome TEXT, ended TEXT, succeeded_attempt TEXT,
      fallback TEXT NOT NULL, failed_attempt TEXT, failed_code TEXT, failed_message TEXT, holders TEXT NOT NULL
    ) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_job_novel ON nf_derived_job (novel, chapter);
    CREATE INDEX nf_derived_job_open ON nf_derived_job (novel, ended);
    CREATE INDEX nf_derived_job_pending ON nf_derived_job (fallback, ended);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .kit([JobSchema.jobKind]) { [$0] },
      .outputs(of: JobAttemptDerivation.self) { [$0.jobRef] },
    ]
  }

  public static func key(of output: JobEntry) -> EntityRef { output.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<JobEntry> {
    guard ref.kind == JobSchema.jobKind else { return JobEntry.filter(sql: "0") }
    return JobEntry.filter(Column("job") == ref.key.rawValue)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(ofKit: JobSchema.jobKind))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [JobEntry] {
    guard ref.kind == JobSchema.jobKind, case .record(let stored)? = try context.records.state(of: ref, scope: .vault) else { return [] }
    guard let job = JobRecords.reading(.record(stored), of: ref).record, let requested = stored[field: JobField.request.rawValue]?.clock else { return [] }
    let attempts = try context.fetchAll(JobAttemptRow.filter(Column("job") == ref.key.rawValue)).sorted { $0.outranks($1) }
    let key = job.request.key
    let latest = attempts.last.map { row in
      JobLatestAttempt(
        attempt: row.attempt, replica: row.replica, leaseExpires: row.leaseExpires, leaseRenewed: row.leaseRenewed, step: row.step, outcome: row.outcome)
    }
    return [
      JobEntry(
        job: ref.key, novel: NovelJobAddress.novel(ofScope: key.scope), chapter: NovelJobAddress.chapter(ofTarget: key.target), kind: key.kind, target: key.target,
        fingerprint: key.fingerprint, run: key.run, requested: requested, requester: job.request.replica, cancel: job.cancel, attempts: attempts.count, latest: latest,
        standing: JobStanding(cancel: job.cancel, attempts: attempts))
    ]
  }
}
