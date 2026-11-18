import Foundation
import GRDB
import ShadowAI
import ShadowStore

/// What one call an attempt names cost, from its ledger entry and the attempts it abandoned (apps/novel-forge-server/src/modules/jobs/job.service.ts:444-480
/// sums by run; here the attempt's call ids stand for the run, orchestrator decision 19).
public struct JobCallCost: Hashable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nf_derived_job_call_cost"

  public let call: UUID
  public let cost: JobCost

  init(call: UUID, cost: JobCost) {
    self.call = call
    self.cost = cost
  }

  public init(row: Row) throws {
    let usage = TokenUsage(
      input: try row.decode(Int.self, forColumn: "input"), output: try row.decode(Int.self, forColumn: "output"),
      cacheRead: try row.decode(Int.self, forColumn: "cache_read"), cacheWriteShort: try row.decode(Int.self, forColumn: "cache_write_short"),
      cacheWriteLong: try row.decode(Int.self, forColumn: "cache_write_long"))
    self.init(
      call: try row.decode(UUID.self, forColumn: "call"),
      cost: JobCost(
        calls: try row.decode(Int.self, forColumn: "entries"), usage: usage, cost: Cost(nanoUSD: try row.decode(Int64.self, forColumn: "cost")),
        estimated: Cost(nanoUSD: try row.decode(Int64.self, forColumn: "estimated")), pendingCalls: try row.decode(Int.self, forColumn: "pending"),
        missingCalls: try row.decode(Int.self, forColumn: "missing")))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["call"] = call
    container["entries"] = cost.calls
    container["input"] = cost.usage.input
    container["output"] = cost.usage.output
    container["cache_read"] = cost.usage.cacheRead
    container["cache_write_short"] = cost.usage.cacheWriteShort
    container["cache_write_long"] = cost.usage.cacheWriteLong
    container["cost"] = cost.cost.nanoUSD
    container["estimated"] = cost.estimated.nanoUSD
    container["pending"] = cost.pendingCalls
    container["missing"] = cost.missingCalls
  }
}

/// Keyed by the call's ledger ref, so a fault on it names an entry and never reads as another novel's.
public struct JobCallCostDerivation: Derivation {
  public static let version = 1
  public static let definition = """
    CREATE TABLE nf_derived_job_call_cost (
      call BLOB PRIMARY KEY, entries INTEGER NOT NULL, input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL,
      cache_write_short INTEGER NOT NULL, cache_write_long INTEGER NOT NULL, cost INTEGER NOT NULL, estimated INTEGER NOT NULL, pending INTEGER NOT NULL,
      missing INTEGER NOT NULL
    ) STRICT, WITHOUT ROWID;
    """

  public init() {}

  public var inputs: [DerivationInput<EntityRef>] {
    [
      .outputs(of: JobCallDerivation.self) { [JobColumns.callRef($0.call)] },
      .outputs(of: ModelCallIndexDerivation.self) { [JobColumns.callRef($0.call)] },
    ]
  }

  public static func key(of output: JobCallCost) -> EntityRef { JobColumns.callRef(output.call) }

  public static func request(for ref: EntityRef) -> QueryInterfaceRequest<JobCallCost> {
    guard let call = JobColumns.uuid(of: ref, LedgerSchema.modelCallKind) else { return JobCallCost.filter(sql: "0") }
    return JobCallCost.filter(Column("call") == call)
  }

  public func allKeys(in context: DerivationContext) throws(StoreError) -> Set<EntityRef> {
    let calls = try context.read { database in try UUID.fetchAll(database, sql: "SELECT DISTINCT call FROM \(JobCallRow.databaseTableName)") }
    return Set(calls.map(JobColumns.callRef))
  }

  public func outputs(for ref: EntityRef, in context: DerivationContext) throws(StoreError) -> [JobCallCost] {
    guard let call = JobColumns.uuid(of: ref, LedgerSchema.modelCallKind) else { return [] }
    guard try context.read({ database in try JobCallRow.filter(Column("call") == call).fetchCount(database) }) > 0 else { return [] }
    // An entry under another call's parent at this call's attempt slot is heard by that call only, so it must not count here.
    let entries = Array(try Ledger.entries(ofCall: call, in: context.records).prefix { ($0.parent ?? $0.id) == call })
    let summed = ChatReplyCost.summing(entries, missing: entries.isEmpty ? 1 : 0)
    return [JobCallCost(call: call, cost: JobCost(summed))]
  }
}

/// A job's, or a chapter's, model spend (apps/novel-forge-server/src/modules/ai/usage/call-usage.ts:37-46), shaped as `ChatReplyCost`.
public struct JobCost: Hashable, Sendable {
  public static let zero = JobCost(calls: 0, usage: .zero, cost: .zero, estimated: .zero, pendingCalls: 0, missingCalls: 0)

  /// Ledger entries read: the calls and every attempt they abandoned.
  public let calls: Int
  public let usage: TokenUsage
  public let cost: Cost
  /// The share of `cost` computed from catalog prices rather than reported by the provider.
  public let estimated: Cost
  public let pendingCalls: Int
  /// Calls an attempt names that this device holds no readable ledger entry for yet.
  public let missingCalls: Int

  /// "cost pending": `cost` is a lower bound until every call is recorded and priced.
  public var isPending: Bool { pendingCalls > 0 || missingCalls > 0 }

  init(calls: Int, usage: TokenUsage, cost: Cost, estimated: Cost, pendingCalls: Int, missingCalls: Int) {
    self.calls = calls
    self.usage = usage
    self.cost = cost
    self.estimated = estimated
    self.pendingCalls = pendingCalls
    self.missingCalls = missingCalls
  }

  init(_ reply: ChatReplyCost) {
    self.init(
      calls: reply.calls, usage: reply.usage, cost: reply.cost, estimated: reply.estimated, pendingCalls: reply.pendingCalls, missingCalls: reply.missingCalls)
  }

  /// Saturating, as `ChatReplyCost.summing` adds.
  static func + (left: JobCost, right: JobCost) -> JobCost {
    let usage = TokenUsage(
      input: saturating(left.usage.input, right.usage.input), output: saturating(left.usage.output, right.usage.output),
      cacheRead: saturating(left.usage.cacheRead, right.usage.cacheRead), cacheWriteShort: saturating(left.usage.cacheWriteShort, right.usage.cacheWriteShort),
      cacheWriteLong: saturating(left.usage.cacheWriteLong, right.usage.cacheWriteLong))
    return JobCost(
      calls: saturating(left.calls, right.calls), usage: usage, cost: Cost(nanoUSD: saturating(left.cost.nanoUSD, right.cost.nanoUSD)),
      estimated: Cost(nanoUSD: saturating(left.estimated.nanoUSD, right.estimated.nanoUSD)), pendingCalls: saturating(left.pendingCalls, right.pendingCalls),
      missingCalls: saturating(left.missingCalls, right.missingCalls))
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(calls)
    hasher.combine(cost)
    hasher.combine(pendingCalls)
    hasher.combine(missingCalls)
  }

  private static func saturating<Count: FixedWidthInteger>(_ left: Count, _ right: Count) -> Count {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Count.max : sum
  }
}
