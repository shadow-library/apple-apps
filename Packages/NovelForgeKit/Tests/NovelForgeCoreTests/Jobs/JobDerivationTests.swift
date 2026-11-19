import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import ShadowAI

private typealias World = JobWorld

private func date(_ seconds: Int64) -> Date { World.instant(seconds).date }

private func insertFault(_ table: String, key: String, in store: VaultStore) async throws {
  _ = try await store.write { transaction in
    try transaction.database.execute(
      sql: "INSERT OR REPLACE INTO \(ProjectionFaults.table) (derivation, key, version, message) VALUES (?, ?, 1, 'probe')", arguments: [table, key])
  }
}

private final class Statements: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  func add(_ statement: String) { lock.withLock { recorded.append(statement) } }

  var all: [String] { lock.withLock { recorded } }
}

private func plans(in store: VaultStore, _ load: @escaping @Sendable (ReadTransaction) throws -> Void) async throws -> (count: Int, scans: [String]) {
  try await store.read { transaction in
    let statements = Statements()
    transaction.database.trace(options: .statement) { event in statements.add(event.expandedDescription) }
    try load(transaction)
    transaction.database.trace(options: [], nil)
    let scans = try statements.all.flatMap { statement in
      try Row.fetchAll(transaction.database, sql: "EXPLAIN QUERY PLAN \(statement)").map { "\(statement) → \($0["detail"] as String)" }
    }.filter { $0.contains("→ SCAN") && !$0.contains(ProjectionFaults.table) }
    return (statements.all.count, scans)
  }
}

private func changeCount(in store: VaultStore) async throws -> Int {
  try await store.read { transaction in try Int.fetchOne(transaction.database, sql: "SELECT COUNT(*) FROM change_log") ?? 0 }
}

@Suite("Job derivations", TestTimeLimit.standard)
struct JobDerivationTests {
  @Test func shouldTurnARunningJobQueuedWhenItsLeaseLapsesWithNoWrite() async throws {
    let (reconciler, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let attempt = try await World.start(job, at: 0, replica: World.replicas[1], in: store)
    let writes = try await changeCount(in: store)

    let early = try await World.activity(at: 10, in: store)
    let entry = try #require(early.entries.value?.first)
    #expect(entry.status == .running(attempt) && entry.chapter == 1 && entry.kind == .known(.generate))
    #expect(entry.runner?.replica == World.replicas[1] && entry.runner?.step == AttemptStep(name: "draft", index: 0))
    #expect(early.generating.value == [1] && early.runningGenerations.value == [1] && early.changesAt == date(360))

    let late = try await World.activity(at: 360, in: store)
    #expect(late.entries.value?.map(\.status) == [.queued] && late.generating.value == [1] && late.runningGenerations.value == [] && late.changesAt == nil)
    #expect(try await World.detail(job, at: 360, in: store).job.value??.status == .queued)
    #expect(try await changeCount(in: store) == writes)

    try await World.update(attempt, AttemptUpdate(lease: .granted(at: World.instant(400))), replica: World.replicas[1], in: store)
    #expect(try await World.activity(at: 401, in: store).entries.value?.map(\.status) == [.running(attempt)])
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldNotCountALeaseStampedTooFarAheadAsLiveUntilItsWindowOpens() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let attempt = try await World.start(job, at: 0, in: store)
    try await World.update(attempt, AttemptUpdate(lease: .granted(at: World.instant(1_000))), in: store)
    let before = try await World.activity(at: 300, in: store)
    #expect(before.entries.value?.map(\.status) == [.queued] && before.changesAt == date(700))
    #expect(try await World.activity(at: 700, in: store).entries.value?.map(\.status) == [.running(attempt)])
  }

  @Test func shouldRankStatusesAsJobStatusDoes() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let first = try await World.start(job, at: 0, seed: 1, in: store)
    try await World.update(first, AttemptUpdate(settlement: .failed(AttemptFailure(code: "ai.timeout", message: "The call timed out."))), in: store)
    let failed = try #require(try await World.detail(job, at: 10, in: store).job.value ?? nil)
    #expect(failed.status == .failed(first, AttemptFailure(code: "ai.timeout", message: "The call timed out.")))
    #expect(try await World.activity(at: 10, in: store).entries.value == [])

    let second = try await World.start(job, at: 20, replica: World.replicas[1], seed: 2, in: store)
    try await World.update(second, AttemptUpdate(settlement: .stoodDown), replica: World.replicas[1], in: store)
    #expect(try await World.detail(job, at: 30, in: store).job.value??.status.phase == .failed)

    let third = try await World.start(job, at: 40, replica: World.replicas[2], seed: 3, in: store)
    #expect(try await World.detail(job, at: 50, in: store).job.value??.status == .running(third))
    _ = try await Projection.write(store) { transaction in try JobRecords.cancel(job, in: &transaction) }
    let cancelled = try await World.detail(job, at: 50, in: store)
    #expect(cancelled.job.value??.status == .cancelled && cancelled.job.value??.runner == nil)
    #expect(try await World.activity(at: 50, in: store).entries.value == [])
    try await World.update(third, AttemptUpdate(settlement: .succeeded), replica: World.replicas[2], in: store)
    let succeeded = try await World.detail(job, at: 60, in: store)
    #expect(succeeded.job.value??.status == .succeeded(third) && succeeded.job.value??.latest?.attempt == third)
    #expect(succeeded.attempts.value?.map(\.id) == [first, second, third])
    #expect(succeeded.attempts.value?.map(\.outcome) == [.failed, .stoodDown, .succeeded])
  }

  @Test func shouldSkipAJobWhoseRequestHasNotArrivedAndPickItUpWhenItDoes() async throws {
    let (reconciler, writer) = try World.store()
    let reader = try Projection.store(reconciler)
    let job = try await World.request(try World.key(chapter: 2), in: writer)
    let attempt = try await World.start(job, at: 0, in: writer)
    let lines = try await Projection.lines(of: writer)
    try await Projection.apply([lines[1]], to: reader)
    let absent = try await World.detail(job, at: 10, in: reader)
    #expect(absent.job == .available(nil) && absent.attempts == .available([]))
    #expect(try await World.activity(at: 10, in: reader).entries.value == [])
    #expect(try await Projection.fetch(JobAttemptRow.all(), in: reader).map(\.attempt) == [attempt])

    try await Projection.apply([lines[0]], to: reader)
    #expect(try await World.activity(at: 10, in: reader).entries.value?.map(\.status) == [.running(attempt)])
    let comparison = try await Projection.compare(reconciler, in: reader)
    #expect(comparison.incremental == comparison.rebuilt)
  }

  @Test func shouldReadACancelThatArrivedBeforeItsRequestAsNoJob() async throws {
    let (_, store) = try World.store()
    let ref = try World.key().ref
    try await Projection.set(ref, [JobField.cancel.rawValue: .string(JobCancel.requested.rawValue)], in: store)
    let absent = try await World.detail(ref, at: 0, in: store)
    #expect(absent.job == .available(nil) && absent.attempts == .available([]))
    try await World.request(try World.key(), in: store)
    #expect(try await World.detail(ref, at: 0, in: store).job.value??.status == .cancelled)
  }

  @Test func shouldSumCostPerJobAndChapterAndSayItIsPendingUntilEveryCallIsPriced() async throws {
    let (_, store) = try World.store()
    let generate = try await World.request(try World.key(chapter: 1), in: store)
    let review = try await World.request(try World.key(chapter: 1, kind: .review), in: store)
    let other = try await World.request(try World.key(chapter: 2), in: store)
    let generating = try await World.start(generate, at: 0, seed: 1, in: store)
    let reviewing = try await World.start(review, at: 0, seed: 2, in: store)
    let (priced, retried, shared, unrecorded) = (World.calls[0], World.calls[1], World.calls[2], World.calls[3])
    try await World.ledger(priced, events: World.finishedEvents(300), in: store)
    try await World.ledger(retried, events: World.retriedEvents(700), in: store)
    try await World.ledger(shared, events: World.finishedEvents(50), in: store)
    for call in [priced, retried, shared] { try await World.update(generating, AttemptUpdate(call: call), in: store) }
    for call in [shared, unrecorded, shared] { try await World.update(reviewing, AttemptUpdate(call: call), in: store) }

    let chapter = try await World.costs(.chapter(novel: World.novel, chapter: 1), in: store)
    let jobs = try #require(chapter.jobs.value)
    #expect(jobs[generate]?.cost == Cost(nanoUSD: 1_050) && jobs[generate]?.calls == 4 && jobs[generate]?.pendingCalls == 1)
    #expect(jobs[review]?.cost == Cost(nanoUSD: 50) && jobs[review]?.missingCalls == 1 && jobs[review]?.isPending == true)
    #expect(chapter.total.value?.cost == Cost(nanoUSD: 1_050) && chapter.total.value?.calls == 4 && chapter.total.value?.missingCalls == 1)
    #expect(chapter.total.value?.usage == TokenUsage(input: 300, output: 60, cacheRead: 15))
    #expect(try await World.costs(.chapter(novel: World.novel, chapter: 2), in: store).jobs.value == [other: .zero])

    let abandoned = Ledger.attemptID(of: retried, index: 0)
    _ = try await Projection.write(store) { transaction in try Ledger.reconcile(id: abandoned, cost: Cost(nanoUSD: 25), in: &transaction) }
    try await World.ledger(unrecorded, events: World.finishedEvents(5), in: store)
    let settled = try await World.costs(.novel(World.novel), in: store)
    #expect(settled.total.value?.cost == Cost(nanoUSD: 1_080) && settled.total.value?.isPending == false)
    #expect(try await World.detail(review, at: 0, in: store).cost.value?.cost == Cost(nanoUSD: 55))
  }

  @Test func shouldReadUnknownRatherThanFailWhenADerivationFaults() async throws {
    let (_, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    try await World.start(job, at: 0, in: store)
    try await insertFault(JobActivityRow.databaseTableName, key: ProjectionFaults.key(World.novel), in: store)
    let activity = try await World.activity(at: 10, in: store)
    #expect(activity.entries.isUnavailable && activity.generating.isUnavailable && activity.changesAt == nil)
    #expect(try await World.activity(World.otherNovel, at: 10, in: store).entries == .available([]))

    try await insertFault(JobEntry.databaseTableName, key: ProjectionFaults.key(job), in: store)
    let detail = try await World.detail(job, at: 10, in: store)
    #expect(detail.job.isUnavailable && detail.attempts.isUnavailable && detail.cost.isUnavailable)

    try await insertFault(JobCallCost.databaseTableName, key: ProjectionFaults.wholeDerivation, in: store)
    let costs = try await World.costs(.novel(World.otherNovel), in: store)
    #expect(costs.total.isUnavailable && costs.jobs.isUnavailable && !costs.faults.isEmpty)
  }

  @Test func shouldCountOpenGenerateJobsAsGeneratingAndRunningOnesApart() async throws {
    let (_, store) = try World.store()
    let first = try await World.request(try World.key(chapter: 1), in: store)
    try await World.request(try World.key(chapter: 2), in: store)
    let review = try await World.request(try World.key(chapter: 3, kind: .review), in: store)
    try await World.start(first, at: 0, seed: 1, in: store)
    try await World.start(review, at: 0, seed: 2, in: store)
    let activity = try await World.activity(at: 10, in: store)
    #expect(activity.generating.value == [1, 2] && activity.runningGenerations.value == [1])
    #expect(activity.entries.value?.map(\.chapter) == [1, 2, 3])
    #expect(activity.running.value?.map(\.chapter) == [1, 3] && activity.queued.value?.map(\.chapter) == [2])
  }

  @Test func shouldReadThroughIndexesWithAStatementCountIndependentOfTheNumberOfJobs() async throws {
    let (_, small) = try World.store()
    let (_, large) = try World.store()
    for (store, chapters) in [(small, 2), (large, 12)] {
      for chapter in 1...chapters {
        let job = try await World.request(try World.key(chapter: chapter), in: store)
        let attempt = try await World.start(job, at: Int64(chapter), seed: UInt64(chapter), in: store)
        try await World.update(attempt, AttemptUpdate(call: World.calls[chapter % 4]), in: store)
      }
    }
    let job = try World.key(chapter: 1).ref
    let loads: [(name: String, load: @Sendable (ReadTransaction) throws -> Void)] = [
      ("JobActivity", { _ = try JobActivity.load(JobActivityQuery(novel: World.novel, now: World.instant(5)), in: $0) }),
      ("JobDetail", { _ = try JobDetail.load(JobDetailQuery(job: job, now: World.instant(5)), in: $0) }),
      ("JobCosts", { _ = try JobCosts.load(.chapter(novel: World.novel, chapter: 1), in: $0) }),
    ]
    for (name, load) in loads {
      let few = try await plans(in: small, load)
      let many = try await plans(in: large, load)
      #expect(few.count == many.count, "\(name): \(few.count) vs \(many.count)")
      #expect(many.scans.isEmpty, "\(name) scans: \(many.scans)")
    }
  }

  @Test func shouldKeepACallsCostOffAnEntryForgedUnderAnotherCallAtItsAttemptSlot() async throws {
    let (reconciler, store) = try World.store()
    let job = try await World.request(try World.key(), in: store)
    let attempt = try await World.start(job, at: 0, in: store)
    let (call, other) = (World.calls[0], World.calls[1])
    try await World.ledger(call, events: World.finishedEvents(300), in: store)
    try await World.update(attempt, AttemptUpdate(call: call), in: store)
    let forged = ModelCallEntry(
      id: Ledger.attemptID(of: call, index: 0), provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: World.epoch,
      parent: other, outcome: .failed, usage: World.usage, cost: Cost(nanoUSD: 40), costSource: .reported)
    try await Projection.write(store) { transaction in try Ledger.open(forged, in: &transaction) }
    _ = try await Projection.write(store) { transaction in try Ledger.reconcile(id: forged.id, cost: Cost(nanoUSD: 70), in: &transaction) }
    let comparison = try await Projection.compare(reconciler, in: store)
    #expect(comparison.incremental == comparison.rebuilt)
    let cost = try await World.costs(.job(job), in: store).jobs.value?[job]
    #expect(cost?.cost == Cost(nanoUSD: 300) && cost?.calls == 1)
  }

  @Test func shouldFlipShadowJobsLivenessExactlyWhereChangesAtSays() {
    var generator = SeededGenerator(seed: 0x617D)
    for _ in 0..<200 {
      let expires = World.epoch + Int64(generator.int(in: 0...5_000_000))
      guard let opens = JobLease.change(expires: expires, after: LeaseInstant(millis: Int64.min / 2, source: .trusted)) else {
        Issue.record("a lease that has not opened has no next change")
        return
      }
      let at = { (millis: Int64) in AttemptLease.isLive(expires: expires, at: LeaseInstant(millis: millis, source: .device)) }
      #expect(!at(opens - 1) && at(opens) && at(expires - 1) && !at(expires))
      #expect(JobLease.change(expires: expires, after: LeaseInstant(millis: opens - 1, source: .trusted)) == opens)
      #expect(JobLease.change(expires: expires, after: LeaseInstant(millis: opens, source: .trusted)) == expires)
      #expect(JobLease.change(expires: expires, after: LeaseInstant(millis: expires, source: .trusted)) == nil)
    }
  }

  @Test func shouldSpellNovelScopesAndChapterTargetsOneWay() {
    let novel = World.novel
    #expect(NovelJobAddress.novel(ofScope: NovelJobAddress.scope(of: novel)) == novel)
    #expect(NovelJobAddress.novel(ofScope: novel.uuidString.uppercased()) == nil)
    #expect(NovelJobAddress.chapter(ofTarget: NovelJobAddress.target(chapter: 12)) == 12)
    for target in ["chapter:0", "chapter:03", "chapter:+3", "chapter-3", "chapter:", "3"] { #expect(NovelJobAddress.chapter(ofTarget: target) == nil, "\(target)") }
  }

  @Test func shouldNeverFaultOnArbitraryStoredJobAttemptOrLedgerValues() async throws {
    let reconciler = try Projection.reconciler()
    try await forAll(iterations: 8, seed: 0x617C) { generator in
      let store = try Projection.store(reconciler)
      let key = try World.key()
      let attempt = try World.attemptID(at: 0, &generator)
      let refs = [key.ref, attempt.ref, Ledger.ref(World.calls[0]), Ledger.ref(Ledger.attemptID(of: World.calls[0], index: 0))]
      let values: [JSONValue] = [
        .null, .int(1), "x", .array([.string(attempt.uuid.uuidString)]), ["job": .string(key.ref.key.rawValue)], .object(key.requestMembers),
        ["expires": .int(World.epoch), "renewed": .int(World.epoch), "clock": "trusted"], ["parent": .string(World.calls[0].uuidString)],
      ]
      for _ in 0..<14 {
        let ref = generator.pick(from: refs)
        let fields = ["request", "cancel", "start", "lease", "step", "calls", "outcome", "error", "call", "usage", "cost_reported"]
        let chosen = Dictionary(uniqueKeysWithValues: fields.filter { _ in generator.chance(0.3) }.map { ($0, generator.pick(from: values)) })
        let purges = generator.chance(0.1)
        do {
          _ = try await store.write { transaction in
            if purges { _ = try transaction.purge(ref) } else { _ = try transaction.set(ref, chosen.isEmpty ? ["outcome": "running"] : chosen) }
          }
        } catch {
          if case StoreError.reconcilerFailed = error { Issue.record("\(error)") }
        }
      }
      let comparison = try await Projection.compare(reconciler, in: store)
      #expect(comparison.incremental == comparison.rebuilt)
      #expect(try await Projection.faults(reconciler, in: store).isEmpty)
    }
  }
}
