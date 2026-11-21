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
  public let reviewKind: ChapterReviewKind?
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

  public func latest(review kind: ChapterReviewKind) -> ChapterJob? { jobs.value?.last { $0.reviewKind == kind } }

  public static func load(_ query: ChapterJobsQuery, in transaction: ReadTransaction) throws(StoreError) -> ChapterJobs {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    var changes: Int64?
    let jobs = try report.section(tables) { () throws(StoreError) in
      let entries = try transaction.query { database in
        try JobEntry.filter(Column("novel") == query.novel && Column("chapter") == query.chapter).fetchAll(database)
      }
      let latest = try latest(of: entries, at: query.now, in: transaction)
      changes = latest.changes
      return latest.jobs
    }
    return ChapterJobs(jobs: jobs, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
  }

  /// One chapter's entries down to the latest job of each kind, a review's kind counting apart, and the next moment one of them changes with no write.
  static func latest(of entries: [JobEntry], at now: LeaseInstant, in transaction: ReadTransaction) throws(StoreError) -> (jobs: [ChapterJob], changes: Int64?) {
    var latest = [String: (entry: JobEntry, reviewKind: ChapterReviewKind?)]()
    for entry in entries {
      let reviewKind = try reviewKind(of: entry, in: transaction)
      let group = reviewKind.map { "\(entry.kind):\($0.rawValue)" } ?? entry.kind
      if latest[group].map({ precedes($0.entry, entry) }) ?? true { latest[group] = (entry, reviewKind) }
    }
    let kept = latest.values.sorted { precedes($0.entry, $1.entry) }.map { ($0.entry, $0.reviewKind) }
    let jobs = kept.map { entry, reviewKind in
      ChapterJob(
        job: entry.ref, kind: entry.jobKind, run: entry.run, requester: entry.requester, status: entry.status(at: now), reviewKind: reviewKind,
        runner: entry.standing.holder(at: now), latest: entry.latest)
    }
    return (jobs, kept.compactMap { $0.0.standing.changes(after: now) }.min())
  }

  private static func reviewKind(of entry: JobEntry, in transaction: ReadTransaction) throws(StoreError) -> ChapterReviewKind? {
    guard entry.jobKind == .known(.review), let state = try transaction.state(of: entry.ref, scope: .vault) else { return nil }
    return JobRecords.reading(state, of: entry.ref).record?.request.payload["kind"]?.stringValue.flatMap { ChapterReviewKind(rawValue: $0) }
  }

  private static func precedes(_ first: JobEntry, _ second: JobEntry) -> Bool {
    if first.requested != second.requested { return first.requested < second.requested }
    if first.run != second.run { return first.run < second.run }
    return first.job.rawValue.utf8.lexicographicallyPrecedes(second.job.rawValue.utf8)
  }
}

public struct NovelChapterJobsQuery: Sendable, Hashable {
  public let novel: UUID
  public let now: LeaseInstant

  public init(novel: UUID, now: LeaseInstant) {
    self.novel = novel
    self.now = now
  }
}

/// `ChapterJobs` of every chapter of the novel that may still show a line, in one read, whether or not the chapter still has a draft or a plan: one with a
/// job neither succeeded nor cancelled that no later job of its kind replaced. A later review replaces one only with the same fingerprint, which names its
/// review kind; reviews of other text are kept, since only their request says which kind they are.
public struct NovelChapterJobs: ReadModel {
  /// Each listed chapter's jobs as `ChapterJobs.jobs` reads them.
  public let chapters: Derived<[Int: [ChapterJob]]>
  public let changesAt: Date?
  public let faults: [ReadFault]

  private static let tables = [JobEntry.databaseTableName]
  /// The wall time and counter of an `HLCTimestamp`'s text, which sort as the clock does; the replica after them is left out so text order never decides.
  private static let clockPrefix = 29

  public var jobs: [ChapterJob] { (chapters.value ?? [:]).sorted { $0.key < $1.key }.flatMap(\.value) }

  public static func load(_ query: NovelChapterJobsQuery, in transaction: ReadTransaction) throws(StoreError) -> NovelChapterJobs {
    let report = try ReadFaults(novel: query.novel, reading: tables, in: transaction)
    var changes: Int64?
    let chapters = try report.section(tables) { () throws(StoreError) in
      let table = JobEntry.databaseTableName
      let review = NovelJobKind.review.rawValue
      let entries = try transaction.query { database in
        try JobEntry.fetchAll(
          database,
          sql: """
            SELECT * FROM \(table) WHERE novel = ? AND chapter IN (
              SELECT e.chapter FROM \(table) e WHERE e.novel = ? AND e.ended IS NULL AND e.chapter IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM \(table) f WHERE f.novel = e.novel AND f.chapter = e.chapter AND f.kind = e.kind
                  AND substr(f.requested, 1, \(Self.clockPrefix)) > substr(e.requested, 1, \(Self.clockPrefix)) AND (f.kind != ? OR f.fingerprint = e.fingerprint)))
            """, arguments: [query.novel, query.novel, review])
      }
      var chapters = [Int: [ChapterJob]]()
      for (chapter, entries) in Dictionary(grouping: entries, by: \.chapter) {
        guard let chapter else { continue }
        let latest = try ChapterJobs.latest(of: entries, at: query.now, in: transaction)
        chapters[chapter] = latest.jobs
        changes = [changes, latest.changes].compactMap { $0 }.min()
      }
      return chapters
    }
    return NovelChapterJobs(chapters: chapters, changesAt: changes.map { Date(timeIntervalSince1970: Double($0) / 1000) }, faults: report.relevant)
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
