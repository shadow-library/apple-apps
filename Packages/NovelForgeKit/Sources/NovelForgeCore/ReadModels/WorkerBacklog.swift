import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct WorkerBacklogQuery: Sendable, Hashable {
  public let replica: ReplicaID
  public let now: LeaseInstant

  public init(replica: ReplicaID, now: LeaseInstant) {
    self.replica = replica
    self.now = now
  }
}

public struct WorkerBacklogEntry: Sendable, Equatable {
  public let job: EntityRef
  public let kind: NovelJobKind
  public let novel: UUID
  public let chapter: Int?
  public let run: Int
  public let requested: HLCTimestamp
  public let requester: ReplicaID
  /// The attempt that started last, nil while none has: where a run whose lease lapsed stopped, and on which replica.
  public let latest: JobLatestAttempt?
}

/// Every job of the vault that queues for the worker and reads queued at `now`: never started, or every attempt's lease lapsed, and neither cancelled,
/// succeeded nor failed (a failed job waits for Try Again), in the order they were requested. The list is the same on every replica; `worker` says
/// whether this one should drain it. Liveness is read against `now`, so a lease that lapses adds its job with no write: re-read at `changesAt`.
public struct WorkerBacklog: ReadModel {
  public let jobs: Derived<[WorkerBacklogEntry]>
  public let worker: VaultWorker
  /// The next moment a job of a kind that queues for the worker enters or leaves the list with no write; nil when none will or the list is unavailable.
  public let changesAt: Date?
  public let faults: [ReadFault]

  private static let tables = [JobEntry.databaseTableName]
  private static let kinds = NovelJobKind.allCases.filter(\.queuesForWorker).map(\.rawValue)

  public var isWorkerHere: Bool { worker.isHere }

  public static func load(_ query: WorkerBacklogQuery, in transaction: ReadTransaction) throws(StoreError) -> WorkerBacklog {
    let report = try ReadFaults(novel: nil, reading: tables, in: transaction)
    let worker = try JobDevices(here: query.replica, in: transaction).worker(in: transaction)
    var changes: Int64?
    let jobs = try report.section(tables) { () throws(StoreError) in
      let entries = try transaction.query { database in
        try JobEntry.filter(Column("fallback") == JobFallback.queued && Column("ended") == nil && Column("novel") != nil && kinds.contains(Column("kind")))
          .fetchAll(database)
      }
      changes = entries.compactMap { $0.standing.changes(after: query.now) }.min()
      return entries.filter { $0.status(at: query.now) == .queued }.sorted(by: precedes).compactMap(entry)
    }
    return WorkerBacklog(jobs: jobs, worker: worker, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
  }

  private static func entry(of entry: JobEntry) -> WorkerBacklogEntry? {
    guard let novel = entry.novel, case .known(let kind) = entry.jobKind else { return nil }
    return WorkerBacklogEntry(
      job: entry.ref, kind: kind, novel: novel, chapter: entry.chapter, run: entry.run, requested: entry.requested, requester: entry.requester,
      latest: entry.latest)
  }

  private static func precedes(_ first: JobEntry, _ second: JobEntry) -> Bool {
    first.requested != second.requested ? first.requested < second.requested : first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
  }
}
