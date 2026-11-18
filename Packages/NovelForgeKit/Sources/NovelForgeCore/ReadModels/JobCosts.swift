import Foundation
import GRDB
import ShadowAI
import ShadowJobs
import ShadowStore

public enum JobCostScope: Sendable, Hashable {
  case job(EntityRef)
  case chapter(novel: UUID, chapter: Int)
  case novel(UUID)
}

/// Spend per job and in total over a scope, from the calls each job's attempts name joined to the ledger (orchestrator decision 19). Every job in scope
/// has a figure, zero when it made no call (apps/novel-forge-server/src/modules/jobs/job.service.ts:443); a call two jobs name counts for each and once in
/// the total. Any fault on the tables a total reads leaves it unavailable, entry faults included, since a withdrawn row would make it read low.
public struct JobCosts: ReadModel {
  public let jobs: Derived<[EntityRef: JobCost]>
  public let total: Derived<JobCost>
  public let faults: [ReadFault]

  static let tables = [JobCallCost.databaseTableName, JobCallRow.databaseTableName, JobEntry.databaseTableName]

  private static let unrecorded = JobCost(calls: 0, usage: .zero, cost: .zero, estimated: .zero, pendingCalls: 0, missingCalls: 1)

  public static func load(_ scope: JobCostScope, in transaction: ReadTransaction) throws(StoreError) -> JobCosts {
    let report = try ReadFaults(novel: scope.novel, reading: tables, in: transaction)
    guard report.relevant.isEmpty else { return JobCosts(jobs: .unavailable(report.relevant), total: .unavailable(report.relevant), faults: report.relevant) }
    if case .job(let ref) = scope, ref.kind != JobSchema.jobKind { return JobCosts(jobs: .available([:]), total: .available(.zero), faults: []) }
    let (inScope, named) = try transaction.query { database in
      (
        try String.fetchAll(database, sql: "SELECT j.job FROM \(JobEntry.databaseTableName) j WHERE \(scope.condition)", arguments: scope.arguments),
        try Row.fetchAll(
          database,
          sql: """
            SELECT DISTINCT c.job AS job, c.call AS call FROM \(JobCallRow.databaseTableName) c JOIN \(JobEntry.databaseTableName) j ON j.job = c.job
            WHERE \(scope.condition)
            """, arguments: scope.arguments)
      )
    }
    let pairs = try named.map { row throws(StoreError) in (job: JobColumns.jobRef(try JobColumns.key(row["job"])), call: row["call"] as UUID) }
    let calls = Set(pairs.map(\.call))
    let costs = try transaction.query { database in
      try JobCallCost.fetchAll(
        database,
        sql: """
          SELECT * FROM \(JobCallCost.databaseTableName) WHERE call IN (
            SELECT c.call FROM \(JobCallRow.databaseTableName) c JOIN \(JobEntry.databaseTableName) j ON j.job = c.job WHERE \(scope.condition)
          )
          """, arguments: scope.arguments)
    }
    let byCall = Dictionary(costs.map { ($0.call, $0.cost) }) { first, _ in first }
    var jobs = [EntityRef: JobCost]()
    for job in inScope { jobs[JobColumns.jobRef(try JobColumns.key(job))] = .zero }
    for pair in pairs { jobs[pair.job, default: .zero] = jobs[pair.job, default: .zero] + (byCall[pair.call] ?? unrecorded) }
    let total = calls.reduce(JobCost.zero) { sum, call in sum + (byCall[call] ?? unrecorded) }
    return JobCosts(jobs: .available(jobs), total: .available(total), faults: report.relevant)
  }
}

extension JobCostScope {
  var novel: UUID? {
    switch self {
    case .job: nil
    case .chapter(let novel, _), .novel(let novel): novel
    }
  }

  var condition: String {
    switch self {
    case .job: "j.job = ?"
    case .chapter: "j.novel = ? AND j.chapter = ?"
    case .novel: "j.novel = ?"
    }
  }

  var arguments: StatementArguments {
    switch self {
    case .job(let ref): [ref.key.rawValue]
    case .chapter(let novel, let chapter): [novel, chapter]
    case .novel(let novel): [novel]
    }
  }
}
