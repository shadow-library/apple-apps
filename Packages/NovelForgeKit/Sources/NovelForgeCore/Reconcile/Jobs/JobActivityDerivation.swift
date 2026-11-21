import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// A novel's open job: one some `now` reads queued or running. Whether it is running is left to the read, since a lease lapses with no write; a job that
/// ended, or failed with no running attempt left, has no row, so the table stays as small as the work in flight.
public struct JobActivityRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_job_activity"

  public let novel: UUID
  public let job: EntityKey
  public let chapter: Int?
  public let kind: String
  public let target: String
  public let run: Int
  public let requested: HLCTimestamp
  public let fallback: JobFallback
  public let holders: [JobLeaseHolder]

  init(novel: UUID, job: EntityKey, chapter: Int?, kind: String, target: String, run: Int, requested: HLCTimestamp, fallback: JobFallback, holders: [JobLeaseHolder]) {
    self.novel = novel
    self.job = job
    self.chapter = chapter
    self.kind = kind
    self.target = target
    self.run = run
    self.requested = requested
    self.fallback = fallback
    self.holders = holders
  }

  public init(row: Row) throws {
    self.init(
      novel: try row.decode(UUID.self, forColumn: "novel"), job: try JobColumns.key(try row.decode(String.self, forColumn: "job")),
      chapter: try row.decode(Int?.self, forColumn: "chapter"), kind: try row.decode(String.self, forColumn: "kind"),
      target: try row.decode(String.self, forColumn: "target"), run: try row.decode(Int.self, forColumn: "run"),
      requested: try JobColumns.clock(try row.decode(String.self, forColumn: "requested")), fallback: try row.decode(JobFallback.self, forColumn: "fallback"),
      holders: try JobStanding.decode(try row.decode(String.self, forColumn: "holders")))
  }

  public var ref: EntityRef { JobColumns.jobRef(job) }

  public var jobKind: StoredEnum<NovelJobKind> { StoredEnum(rawValue: kind) }

  /// Running when a holder's lease is live at `now`, else queued unless it failed, which no activity shows.
  public func status(at now: LeaseInstant) -> JobStatus? {
    if let runner = holders.live(at: now) { return .running(runner.attempt) }
    return fallback == .queued ? .queued : nil
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["novel"] = novel
    container["job"] = job.rawValue
    container["chapter"] = chapter
    container["kind"] = kind
    container["target"] = target
    container["run"] = run
    container["requested"] = requested.description
    container["fallback"] = fallback
    container["holders"] = JobStanding.encode(holders)
  }
}

public struct JobActivityDerivation: Derivation {
  public static let version = 2
  public static let definition = """
    CREATE TABLE nf_derived_job_activity (
      novel BLOB NOT NULL, job TEXT NOT NULL, chapter INTEGER, kind TEXT NOT NULL, target TEXT NOT NULL, run INTEGER NOT NULL, requested TEXT NOT NULL,
      fallback TEXT NOT NULL, holders TEXT NOT NULL, PRIMARY KEY (novel, job)
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<UUID>] {
    [.outputs(of: JobEntryDerivation.self) { $0.novel.map { [$0] } ?? [] }]
  }

  public static func key(of output: JobActivityRow) -> UUID { output.novel }

  public static func request(for novel: UUID) -> QueryInterfaceRequest<JobActivityRow> {
    JobActivityRow.filter(Column("novel") == novel)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<UUID> {
    Set(try context.read { database in try UUID.fetchAll(database, sql: "SELECT DISTINCT novel FROM \(JobEntry.databaseTableName) WHERE novel IS NOT NULL") })
  }

  public func outputs(for novel: UUID, in context: DerivationContext) throws(StoreError) -> [JobActivityRow] {
    let open = try context.fetchAll(JobEntry.filter(Column("novel") == novel && Column("ended") == nil)).filter(\.standing.isOpen)
    return open.map { entry in
      JobActivityRow(
        novel: novel, job: entry.job, chapter: entry.chapter, kind: entry.kind, target: entry.target, run: entry.run, requested: entry.requested,
        fallback: entry.standing.fallback, holders: entry.standing.holders)
    }
  }
}
