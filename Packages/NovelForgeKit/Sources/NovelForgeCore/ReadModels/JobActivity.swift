import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

public struct JobActivityQuery: Sendable, Hashable {
  public let novel: UUID
  public let now: LeaseInstant

  public init(novel: UUID, now: LeaseInstant) {
    self.novel = novel
    self.now = now
  }
}

public struct JobActivityEntry: Sendable, Equatable {
  public let job: EntityRef
  public let kind: StoredEnum<NovelJobKind>
  public let target: String
  public let chapter: Int?
  public let run: Int
  public let requested: HLCTimestamp
  /// `.queued` or `.running`.
  public let status: JobStatus
  /// The attempt holding the live lease: which device runs it and at which step.
  public let runner: JobLeaseHolder?
}

/// A novel's work in flight at `now`: what is running, what is queued, which chapters are generating. Liveness is read against `now`, so a lease that
/// lapses turns a running job queued with no write; observing the store does not notice that, so a screen re-reads at `changesAt`.
public struct JobActivity: ReadModel {
  /// Chapter order, then the order the jobs were requested in; jobs that target no chapter come last.
  public let entries: Derived<[JobActivityEntry]>
  /// The next moment some entry's status changes with no write; nil when none will or the activity is unavailable.
  public let changesAt: Date?
  public let faults: [ReadFault]

  private static let tables = [JobActivityRow.databaseTableName]

  public var running: Derived<[JobActivityEntry]> { entries.map { $0.filter { $0.status.phase == .running } } }

  public var queued: Derived<[JobActivityEntry]> { entries.map { $0.filter { $0.status.phase == .queued } } }

  /// The chapters with an open generate job, queued or running, as apps/novel-forge-server/src/modules/generation/generation.service.ts:242-243 counts
  /// `pending` and `in_progress` alike.
  public var generating: Derived<[Int]> { generations { _ in true } }

  /// The chapters a generate job is running for at `now`.
  public var runningGenerations: Derived<[Int]> { generations { $0.status.phase == .running } }

  private func generations(_ included: (JobActivityEntry) -> Bool) -> Derived<[Int]> {
    entries.map { entries in Array(Set(entries.compactMap { $0.kind == .known(.generate) && included($0) ? $0.chapter : nil })).sorted() }
  }

  public func chapter(_ chapter: Int) -> Derived<[JobActivityEntry]> { entries.map { $0.filter { $0.chapter == chapter } } }

  public static func load(_ query: JobActivityQuery, in transaction: ReadTransaction) throws(StoreError) -> JobActivity {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    var changes: Int64?
    let entries = try report.section(tables) { () throws(StoreError) in
      let rows = try transaction.query { database in try JobActivityRow.filter(Column("novel") == query.novel).fetchAll(database) }
      changes = rows.compactMap { $0.holders.nextChange(after: query.now) }.min()
      return rows.sorted(by: precedes).compactMap { entry(of: $0, at: query.now) }
    }
    return JobActivity(entries: entries, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
  }

  private static func entry(of row: JobActivityRow, at now: LeaseInstant) -> JobActivityEntry? {
    guard let status = row.status(at: now) else { return nil }
    return JobActivityEntry(
      job: row.ref, kind: row.jobKind, target: row.target, chapter: row.chapter, run: row.run, requested: row.requested, status: status,
      runner: row.holders.live(at: now))
  }

  private static func precedes(_ first: JobActivityRow, _ second: JobActivityRow) -> Bool {
    if first.chapter != second.chapter { return (first.chapter ?? Int.max) < (second.chapter ?? Int.max) }
    if first.requested != second.requested { return first.requested < second.requested }
    return first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
  }
}
