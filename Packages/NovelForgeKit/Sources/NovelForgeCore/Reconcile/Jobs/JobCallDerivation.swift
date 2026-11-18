import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore

/// A model call a readable attempt names in its cumulative `calls` (orchestrator decision 19).
public struct JobCallRow: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_job_call"

  public let attempt: AttemptID
  public let call: UUID
  public let job: EntityKey

  init(attempt: AttemptID, call: UUID, job: EntityKey) {
    self.attempt = attempt
    self.call = call
    self.job = job
  }

  public init(row: Row) throws {
    self.init(
      attempt: try JobColumns.attempt(try row.decode(String.self, forColumn: "attempt")), call: try row.decode(UUID.self, forColumn: "call"),
      job: try JobColumns.key(try row.decode(String.self, forColumn: "job")))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["attempt"] = attempt.uuid.lowercasedString
    container["call"] = call
    container["job"] = job.rawValue
  }
}

public struct JobCallDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_job_call (attempt TEXT NOT NULL, call BLOB NOT NULL, job TEXT NOT NULL, PRIMARY KEY (attempt, call)) STRICT, WITHOUT ROWID;
    CREATE INDEX nf_derived_job_call_job ON nf_derived_job_call (job, call);
    CREATE INDEX nf_derived_job_call_call ON nf_derived_job_call (call);
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [.kit([JobSchema.attemptKind]) { [$0] }]
  }

  public static func key(of output: JobCallRow) -> EntityRef { output.attempt.ref }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<JobCallRow> {
    guard let id = JobColumns.uuid(of: ref, JobSchema.attemptKind) else { return JobCallRow.filter(sql: "0") }
    return JobCallRow.filter(Column("attempt") == id.lowercasedString)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    Set(try context.refs(ofKit: JobSchema.attemptKind))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [JobCallRow] {
    guard ref.kind == JobSchema.attemptKind, let record = AttemptRecords.reading(try context.records.state(of: ref, scope: .vault), of: ref).record else { return [] }
    return Set(record.calls).map { JobCallRow(attempt: record.id, call: $0, job: record.start.job.key) }
  }
}
