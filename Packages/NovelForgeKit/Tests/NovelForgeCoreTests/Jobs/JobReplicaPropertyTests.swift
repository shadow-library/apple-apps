import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore

/// Surfaces its message through the store's `aborted` wrapper, which reports only `localizedDescription`.
private struct JobOracleFailure: LocalizedError {
  let errorDescription: String?

  init(_ message: String) { errorDescription = message }
}

private final class Reached: Sendable {
  private let seen = Mutex<Set<String>>([])

  func insert(_ state: String) { seen.withLock { _ = $0.insert(state) } }

  var all: Set<String> { seen.withLock { $0 } }
}

/// Moments around every stored lease's window, plus a sweep, so read-time liveness is compared on both sides of each boundary.
private func moments(_ snapshots: [JobSnapshot]) -> [LeaseInstant] {
  var millis = Set(stride(from: -60, through: 3_400, by: 197).map { JobWorld.epoch + Int64($0) * 1000 })
  for attempt in snapshots.flatMap(\.attempts) {
    guard let expires = attempt.lease?.expires else { continue }
    let opens = expires - 660_000
    millis.formUnion([opens - 1, opens, expires - 1, expires, expires + 1])
  }
  return millis.sorted().map { LeaseInstant(millis: $0, source: .trusted) }
}

private func jobOracle(_ store: VaultStore, _ universe: ProjectionUniverse, _ reached: Reached) async throws {
  try await store.read { transaction in
    let refs = try transaction.states(ofKind: JobSchema.jobKind).map(\.ref)
    let snapshots = try refs.compactMap { ref in try JobSnapshot.load(ref, in: transaction) }
    let now = moments(snapshots)
    for ref in refs where try JobSnapshot.load(ref, in: transaction) == nil {
      let detail = try JobDetail.load(JobDetailQuery(job: ref, now: now[0]), in: transaction)
      guard detail.job == .available(nil), detail.attempts == .available([]) else { throw JobOracleFailure("a job whose request has not arrived has a row") }
      reached.insert("request not arrived")
    }
    var statuses = [EntityRef: [(status: JobStatus, changesAt: Date?)]]()
    var activities = [UUID: [(entries: Set<String>, changesAt: Date?)]]()
    for moment in now {
      for snapshot in snapshots {
        let expected = JobStatus(snapshot, at: moment)
        let detail = try JobDetail.load(JobDetailQuery(job: snapshot.job.ref, now: moment), in: transaction)
        guard detail.job.value??.status == expected else { throw JobOracleFailure("status of \(snapshot.job.ref.key) at \(moment.millis)") }
        guard detail.attempts.value?.map(\.id) == snapshot.attempts.map(\.id) else { throw JobOracleFailure("attempts of \(snapshot.job.ref.key)") }
        statuses[snapshot.job.ref, default: []].append((expected, detail.job.value??.changesAt))
        reached.insert(expected.phase.rawValue)
      }
      for novel in universe.novels {
        let activity = try JobActivity.load(JobActivityQuery(novel: novel, now: moment), in: transaction)
        let expected = Set(
          snapshots.compactMap { snapshot -> String? in
            let status = JobStatus(snapshot, at: moment)
            guard NovelJobAddress.novel(ofScope: snapshot.job.request.key.scope) == novel, [.queued, .running].contains(status.phase) else { return nil }
            return "\(snapshot.job.ref.key) \(status)"
          })
        guard let entries = activity.entries.value, Set(entries.map { "\($0.job.key) \($0.status)" }) == expected else {
          throw JobOracleFailure("activity of \(novel) at \(moment.millis): \(activity.entries.value.map { Set($0.map { "\($0.job.key) \($0.status)" }) } ?? []) vs \(expected)")
        }
        activities[novel, default: []].append((expected, activity.changesAt))
      }
    }
    for (ref, read) in statuses where !unchangedUntilChangesAt(read.map { ($0.status, $0.changesAt) }, at: now) {
      throw JobOracleFailure("status of \(ref.key) changed before its changesAt")
    }
    for (novel, read) in activities where !unchangedUntilChangesAt(read.map { ($0.entries, $0.changesAt) }, at: now) {
      throw JobOracleFailure("activity of \(novel) changed before its changesAt")
    }
    try costOracle(snapshots, universe, reached, in: transaction)
  }
}

/// `changesAt` is sound: every sampled moment after a read and before its `changesAt` reads the same, and nil means nothing changes later.
private func unchangedUntilChangesAt<Value: Equatable>(_ reads: [(Value, Date?)], at moments: [LeaseInstant]) -> Bool {
  reads.indices.allSatisfy { index in
    let until = reads[index].1.map { LeaseInstant(date: $0, source: .trusted).millis } ?? Int64.max
    return reads.indices.allSatisfy { later in later <= index || moments[later].millis >= until || reads[later].0 == reads[index].0 }
  }
}

private func costOracle(_ snapshots: [JobSnapshot], _ universe: ProjectionUniverse, _ reached: Reached, in transaction: ReadTransaction) throws {
  let direct = { (calls: Set<UUID>) throws -> JobCost in
    var (entries, missing) = ([ModelCallEntry](), 0)
    for call in calls {
      let own = try Ledger.entries(ofCall: call, in: transaction).prefix { ($0.parent ?? $0.id) == call }
      if own.isEmpty { missing += 1 }
      entries += own
    }
    return JobCost(ChatReplyCost.summing(entries, missing: missing))
  }
  for snapshot in snapshots {
    let calls = Set(snapshot.attempts.flatMap(\.calls))
    let costs = try JobCosts.load(.job(snapshot.job.ref), in: transaction)
    guard costs.jobs.value?[snapshot.job.ref] == (try direct(calls)) else { throw JobOracleFailure("cost of \(snapshot.job.ref.key)") }
    if !calls.isEmpty { reached.insert(costs.total.value?.isPending == true ? "cost pending" : "cost settled") }
  }
  for novel in universe.novels {
    for chapter in 1...2 {
      let jobs = snapshots.filter {
        NovelJobAddress.novel(ofScope: $0.job.request.key.scope) == novel && NovelJobAddress.chapter(ofTarget: $0.job.request.key.target) == chapter
      }
      let calls = Set(jobs.flatMap { $0.attempts.flatMap(\.calls) })
      if calls.contains(where: { call in jobs.count { $0.attempts.contains { $0.calls.contains(call) } } > 1 }) { reached.insert("call shared by two jobs of one chapter") }
      let total = try JobCosts.load(.chapter(novel: novel, chapter: chapter), in: transaction).total.value
      guard total == (try direct(calls)) else { throw JobOracleFailure("cost of chapter \(chapter) of \(novel)") }
    }
  }
}

@Suite("Job replicas", TestTimeLimit.property)
struct JobReplicaPropertyTests {
  @Test(arguments: [CausalReplicaOrder.causal, .writerOrderOnly])
  func shouldDeriveJobStatusActivityAndCostEqualAcrossReplicasAndToTheSnapshotsAtEveryMoment(order: CausalReplicaOrder) async throws {
    let reached = Reached()
    let property = ProjectionProperty(
      derivations: JobDerivations.all, operations: ProjectionOperations.jobs, iterations: 12, steps: 140, gated: true,
      settled: { _, store, universe in try await jobOracle(store, universe, reached) })
    try await property.check(order: order, seed: order == .causal ? 0x617A : 0x617B)
    let seen = reached.all
    for state in JobPhase.allCases.map(\.rawValue) + ["request not arrived", "cost pending", "cost settled", "call shared by two jobs of one chapter"] {
      #expect(seen.contains(state), "no settled replica reached \(state)")
    }
    for event in ["abandoned attempt priced after its call is named", "ledger edge forged"] {
      #expect(JobOperations.events.contains(event), "no operation reached \(event)")
    }
  }
}
