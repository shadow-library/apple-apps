import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct ChapterJobsQuery: Sendable, Hashable {
  public let novel: UUID
  public let chapter: Int
  public let now: LeaseInstant

  public init(novel: UUID, chapter: Int, now: LeaseInstant) {
    self.novel = novel
    self.chapter = chapter
    self.now = now
  }
}

public struct ChapterJob: Sendable, Equatable {
  public let job: EntityRef
  public let kind: StoredEnum<NovelJobKind>
  public let run: Int
  public let requester: ReplicaID
  public let status: JobStatus
  /// The attempt holding the live lease at `now`: which device runs it and at which step.
  public let runner: JobLeaseHolder?
  /// The attempt that started last, whatever its outcome.
  public let latest: JobLatestAttempt?
}

/// A chapter's latest job of each kind at `now`, for showing what runs for it and offering cancel, "Run here" and a retry; whether a start may go ahead is
/// decided by the engine from `JobSnapshot`, never from these rows. Liveness is read against `now`, so a screen re-reads at `changesAt`.
public struct ChapterJobs: ReadModel {
  /// The order the kinds' latest jobs were requested in.
  public let jobs: Derived<[ChapterJob]>
  public let changesAt: Date?
  public let faults: [ReadFault]

  private static let tables = [JobEntry.databaseTableName]

  public func latest(_ kind: NovelJobKind) -> ChapterJob? { jobs.value?.last { $0.kind == .known(kind) } }

  public static func load(_ query: ChapterJobsQuery, in transaction: ReadTransaction) throws(StoreError) -> ChapterJobs {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    var changes: Int64?
    let jobs = try report.section(tables) { () throws(StoreError) in
      let entries = try transaction.query { database in
        try JobEntry.filter(Column("novel") == query.novel && Column("chapter") == query.chapter).fetchAll(database)
      }
      var latest = [String: JobEntry]()
      for entry in entries where latest[entry.kind].map({ precedes($0, entry) }) ?? true { latest[entry.kind] = entry }
      let kept = latest.values.sorted(by: precedes)
      changes = kept.compactMap { $0.standing.changes(after: query.now) }.min()
      return kept.map { entry in
        ChapterJob(
          job: entry.ref, kind: entry.jobKind, run: entry.run, requester: entry.requester, status: entry.status(at: query.now), runner: entry.standing.holder(at: query.now),
          latest: entry.latest)
      }
    }
    return ChapterJobs(jobs: jobs, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
  }

  private static func precedes(_ first: JobEntry, _ second: JobEntry) -> Bool {
    if first.requested != second.requested { return first.requested < second.requested }
    if first.run != second.run { return first.run < second.run }
    return first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
  }
}

/// The jobs `replica` asked for that no attempt has started and nothing ended, in the order they were requested: the device that requested a job runs it
/// (orchestrator decision 9), so these are what it starts at launch and as requests arrive.
public struct JobBacklog: ReadModel {
  public let jobs: Derived<[EntityRef]>
  public let faults: [ReadFault]

  private static let tables = [JobEntry.databaseTableName]

  public static func load(_ replica: ReplicaID, in transaction: ReadTransaction) throws(StoreError) -> JobBacklog {
    let report = try ReadFaults(novel: nil, reading: tables, in: transaction)
    let jobs = try report.section(tables) { () throws(StoreError) in
      let entries = try transaction.query { database in
        try JobEntry.filter(
          Column("requester") == replica.description && Column("attempts") == 0 && Column("ended") == nil && Column("cancel") == JobCancel.none.rawValue
            && Column("novel") != nil
        ).fetchAll(database)
      }
      return entries.sorted { first, second in
        first.requested != second.requested ? first.requested < second.requested : first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
      }.map(\.ref)
    }
    return JobBacklog(jobs: jobs, faults: report.relevant)
  }
}
