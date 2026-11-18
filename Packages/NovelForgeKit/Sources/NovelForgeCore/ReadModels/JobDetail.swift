import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct JobDetailQuery: Sendable, Hashable {
  public let job: EntityRef
  public let now: LeaseInstant

  public init(job: EntityRef, now: LeaseInstant) {
    self.job = job
    self.now = now
  }
}

public struct JobSummary: Sendable, Equatable {
  public let job: EntityRef
  public let novel: UUID?
  public let chapter: Int?
  public let kind: StoredEnum<NovelJobKind>
  public let target: String
  public let fingerprint: String
  public let run: Int
  public let requested: HLCTimestamp
  public let requester: ReplicaID
  public let cancel: JobCancel
  public let status: JobStatus
  /// The attempt that started last, whatever its outcome.
  public let latest: JobLatestAttempt?
  /// The attempt holding the live lease at `now`.
  public let runner: JobLeaseHolder?
  /// The next moment `status` changes with no write.
  public let changesAt: Date?
}

public struct JobAttemptSummary: Sendable, Equatable {
  public let id: AttemptID
  public let replica: ReplicaID
  public let started: LeaseInstant
  public let byHand: Bool
  public let leaseExpires: Date?
  public let leaseRenewed: Date?
  public let step: AttemptStep?
  public let outcome: AttemptOutcome
  public let error: AttemptFailure?
  /// Distinct model calls it names.
  public let calls: Int
  public let isLive: Bool
}

/// One job at `now`: its request, status, attempts in rank order and spend. A job whose request has not arrived, or cannot be read, reads as nil, with no
/// attempts, as every job reader skips it. A fault on one attempt's row does not block the read (its key names no job), so this is for showing a job:
/// whether to "Run here" is decided from `JobSnapshot` and `AttemptVerdict`, never from these rows.
public struct JobDetail: ReadModel {
  public let job: Derived<JobSummary?>
  public let attempts: Derived<[JobAttemptSummary]>
  public let cost: Derived<JobCost>
  public let faults: [ReadFault]

  private static let jobTables = [JobEntry.databaseTableName]
  private static let attemptTables = [JobEntry.databaseTableName, JobAttemptRow.databaseTableName]

  public static func load(_ query: JobDetailQuery, in transaction: ReadTransaction) throws(StoreError) -> JobDetail {
    let report = try ChatReadFaults(novel: nil, subject: query.job, reading: jobTables + attemptTables + JobCosts.tables, in: transaction)
    let entry = try transaction.query { database in try JobEntryDerivation.request(for: query.job).fetchOne(database) }
    let costs = try JobCosts.load(.job(query.job), in: transaction)
    return JobDetail(
      job: try report.section(jobTables) { () throws(StoreError) in entry.map { summary(of: $0, at: query.now) } },
      attempts: try report.section(attemptTables) { () throws(StoreError) in
        guard entry != nil else { return [] }
        let rows = try transaction.query { database in try JobAttemptRow.filter(Column("job") == query.job.key.rawValue).fetchAll(database) }
        return rows.sorted { $0.outranks($1) }.map { attempt(of: $0, at: query.now) }
      },
      cost: costs.total, faults: report.relevant)
  }

  private static func summary(of entry: JobEntry, at now: LeaseInstant) -> JobSummary {
    JobSummary(
      job: entry.ref, novel: entry.novel, chapter: entry.chapter, kind: entry.jobKind, target: entry.target, fingerprint: entry.fingerprint, run: entry.run,
      requested: entry.requested, requester: entry.requester, cancel: entry.cancel, status: entry.status(at: now), latest: entry.latest,
      runner: entry.standing.holder(at: now),
      changesAt: entry.standing.changes(after: now).map(date))
  }

  private static func attempt(of row: JobAttemptRow, at now: LeaseInstant) -> JobAttemptSummary {
    JobAttemptSummary(
      id: row.attempt, replica: row.replica, started: row.started, byHand: row.byHand, leaseExpires: row.leaseExpires.map(date),
      leaseRenewed: row.leaseRenewed.map(date), step: row.step, outcome: row.outcome, error: row.error, calls: row.calls, isLive: row.isLive(at: now))
  }

  private static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}
