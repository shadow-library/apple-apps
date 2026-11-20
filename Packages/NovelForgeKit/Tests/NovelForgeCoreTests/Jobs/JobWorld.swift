import Foundation
import GRDB
import ShadowCore
import ShadowJobs
import ShadowStore
import ShadowTestSupport
import ShadowText
import Synchronization

@testable import NovelForgeCore
@testable import ShadowAI

enum JobWorld {
  static let epoch: Int64 = 1_800_000_000_000
  static let novel = SchemaFixture.novel
  static let otherNovel = SchemaFixture.otherNovel
  static let replicas = (1...3).map { ReplicaID(UUID(uuidString: String(format: "00000000-0000-7000-8000-%012d", $0)) ?? UUID()) }
  static let calls = (1...4).map { UUID(uuidString: String(format: "6c000000-0000-4000-8000-%012d", $0)) ?? UUID() }

  static func instant(_ seconds: Int64, _ source: AttemptClockSource = .trusted) -> LeaseInstant {
    LeaseInstant(millis: epoch + seconds * 1000, source: source)
  }

  static func key(novel: UUID = novel, chapter: Int = 1, kind: NovelJobKind = .generate, run: Int = 1) throws -> JobKey {
    try JobKey(
      scope: NovelJobAddress.scope(of: novel), kind: kind.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: "f:\(chapter)", run: run)
  }

  static func attemptID(at seconds: Int64, _ generator: inout SeededGenerator) throws -> AttemptID {
    try AttemptID(UUID.v7(at: instant(seconds).date, using: &generator))
  }

  static func store() throws -> (NovelForgeReconciler, VaultStore) {
    let reconciler = try Projection.reconciler()
    return (reconciler, try Projection.store(reconciler))
  }

  @discardableResult
  static func request(_ key: JobKey, replica: ReplicaID = replicas[0], in store: VaultStore) async throws -> EntityRef {
    let request = JobRequest(key: key, payload: ["target": .string(key.target)], replica: replica)
    _ = try await Projection.write(store) { transaction in try JobRecords.request(request, in: &transaction) }
    return key.ref
  }

  @discardableResult
  static func start(_ job: EntityRef, at seconds: Int64, replica: ReplicaID = replicas[0], byHand: Bool = false, seed: UInt64 = 1, in store: VaultStore) async throws
    -> AttemptID
  {
    var generator = SeededGenerator(seed: seed)
    let id = try attemptID(at: seconds, &generator)
    let start = AttemptStart(job: job, replica: replica, started: instant(seconds), byHand: byHand, pinned: .null)
    _ = try await Projection.write(store) { transaction in try AttemptRecords.start(id, start, step: AttemptStep(name: "draft", index: 0), in: &transaction) }
    return id
  }

  static func update(_ id: AttemptID, _ update: AttemptUpdate, replica: ReplicaID = replicas[0], in store: VaultStore) async throws {
    _ = try await Projection.write(store) { transaction in try AttemptRecords.update(id, update, by: replica, in: &transaction) }
  }

  static func activity(_ novel: UUID = novel, at seconds: Int64, in store: VaultStore) async throws -> JobActivity {
    try await store.load(JobActivity.self, JobActivityQuery(novel: novel, now: instant(seconds)))
  }

  static func detail(_ job: EntityRef, at seconds: Int64, in store: VaultStore) async throws -> JobDetail {
    try await store.load(JobDetail.self, JobDetailQuery(job: job, now: instant(seconds)))
  }

  static func costs(_ scope: JobCostScope, in store: VaultStore) async throws -> JobCosts {
    try await store.load(JobCosts.self, scope)
  }

  static func callStart(_ id: UUID) -> ModelCallStart {
    ModelCallStart(id: id, provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: epoch)
  }

  static let usage = TokenUsage(input: 100, output: 20, cacheRead: 5)

  static func finishedEvents(_ nanoUSD: Int64) -> [ModelEvent] {
    [.started(requestID: "r", generationID: "g"), .finished(usage: usage, reportedCost: Cost(nanoUSD: nanoUSD), stop: .endTurn)]
  }

  /// One billed attempt abandoned, whose price is not reported yet, then a finish the provider priced.
  static func retriedEvents(_ nanoUSD: Int64) -> [ModelEvent] {
    [
      .started(requestID: "r1", generationID: "g1"), .retrying(attempt: 1, delay: .seconds(1), cause: .server(status: 500), requestID: "r1", generationID: "g1"),
      .started(requestID: "r2", generationID: "g2"), .finished(usage: usage, reportedCost: Cost(nanoUSD: nanoUSD), stop: .endTurn),
    ]
  }

  static func ledger(_ call: UUID, events: [ModelEvent], in store: VaultStore) async throws {
    let start = callStart(call)
    _ = try await Projection.write(store) { transaction in
      try Ledger.begin(start, in: &transaction)
      return try Ledger.finish(start, events: events, endedWith: nil, catalog: nil, in: &transaction)
    }
  }
}

/// Random job requests, cancels, attempts, lease renewals, steps, calls, outcomes and ledger entries, with raw shapes and purges. Writes name the
/// attempt's own replica as writer whichever store runs them, so the states reached are a superset of the single-writer ones.
enum JobOperations {
  private static let seen = Mutex<Set<String>>([])

  /// Orderings the operations reached, for a property to gate on.
  static var events: Set<String> { seen.withLock { $0 } }

  private static func reached(_ event: String) { seen.withLock { _ = $0.insert(event) } }
  private static func keys(_ universe: ProjectionUniverse) -> [JobKey] {
    let busy: [(Int, NovelJobKind, Int)] = [(1, .generate, 1), (1, .generate, 2), (2, .generate, 1), (1, .review, 1), (2, .plan, 1)]
    var keys = zip(universe.novels, [busy, [(1, .generate, 1)]]).flatMap { novel, jobs in
      jobs.compactMap { chapter, kind, run in try? JobWorld.key(novel: novel, chapter: chapter, kind: kind, run: run) }
    }
    if let vault = try? JobKey(scope: "vault", kind: "audit", target: "all", fingerprint: "f", run: 1) { keys.append(vault) }
    return keys
  }

  private static func job(_ generator: inout SeededGenerator, _ universe: ProjectionUniverse) -> JobKey { generator.pick(from: keys(universe)) }

  private static func seconds(_ generator: inout SeededGenerator) -> Int64 { Int64(generator.int(in: 0...1_500)) }

  private static func known(in transaction: borrowing WriteTransaction, pick: Int) throws -> EntityRef? {
    let jobs = try transaction.states(ofKind: JobSchema.jobKind).filter { JobRecords.reading($0.state, of: $0.ref).record != nil }.map(\.ref).sorted()
    return jobs.isEmpty ? nil : jobs[pick % jobs.count]
  }

  private static func attempts(in transaction: borrowing WriteTransaction) throws -> [AttemptRecord] {
    try transaction.states(ofKind: JobSchema.attemptKind).compactMap { AttemptRecords.reading($0.state, of: $0.ref).record }.sorted {
      $0.id.uuid.lowercasedString < $1.id.uuid.lowercasedString
    }
  }

  private static func running(in transaction: borrowing WriteTransaction, pick: Int) throws -> AttemptRecord? {
    let running = try attempts(in: transaction).filter { $0.outcome == .running }
    return running.isEmpty ? nil : running[pick % running.count]
  }

  static let all: [ProjectionOperation] = [
    ProjectionOperation(name: "request job", weight: 4) { generator, universe in
      let request = JobRequest(key: job(&generator, universe), payload: .null, replica: generator.pick(from: JobWorld.replicas))
      return { transaction in _ = try JobRecords.request(request, in: &transaction) }
    },
    ProjectionOperation(name: "cancel job", weight: 1) { generator, universe in
      let ref = job(&generator, universe).ref
      return { transaction in _ = try JobRecords.cancel(ref, in: &transaction) }
    },
    ProjectionOperation(name: "cancel a job whose request has not arrived", weight: 1) { generator, universe in
      let ref = job(&generator, universe).ref
      return { transaction in
        guard try transaction.state(of: ref) == nil else { return }
        _ = try transaction.set(ref, [JobField.cancel.rawValue: .string(JobCancel.requested.rawValue)])
      }
    },
    ProjectionOperation(name: "start attempt", weight: 5) { generator, _ in
      let (pick, at) = (generator.int(in: 0...99), seconds(&generator))
      let id = try? JobWorld.attemptID(at: at, &generator)
      let source: AttemptClockSource = generator.chance(0.2) ? .device : .trusted
      let (replica, byHand) = (generator.pick(from: JobWorld.replicas), generator.chance(0.2))
      let step = generator.chance(0.5) ? AttemptStep(name: "draft", index: 0) : nil
      return { transaction in
        guard let id, let job = try known(in: transaction, pick: pick) else { return }
        let start = AttemptStart(job: job, replica: replica, started: JobWorld.instant(at, source), byHand: byHand, pinned: .null)
        _ = try AttemptRecords.start(id, start, step: step, in: &transaction)
      }
    },
    ProjectionOperation(name: "renew lease", weight: 4) { generator, _ in
      let pick = generator.int(in: 0...99)
      let at = generator.chance(0.15) ? Int64(generator.int(in: 1_800...2_600)) : seconds(&generator)
      let lease = AttemptLease.granted(at: JobWorld.instant(at))
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick) else { return }
        _ = try AttemptRecords.update(attempt.id, AttemptUpdate(lease: lease), by: attempt.start.replica, in: &transaction)
      }
    },
    ProjectionOperation(name: "advance step", weight: 1) { generator, _ in
      let pick = generator.int(in: 0...99)
      let step = AttemptStep(name: generator.pick(from: ["draft", "expand", "judge"]), index: generator.int(in: 0...3))
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick) else { return }
        _ = try AttemptRecords.update(attempt.id, AttemptUpdate(step: step), by: attempt.start.replica, in: &transaction)
      }
    },
    ProjectionOperation(name: "record call", weight: 4) { generator, _ in
      let (pick, call) = (generator.int(in: 0...99), generator.pick(from: JobWorld.calls))
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick) else { return }
        _ = try AttemptRecords.recordCall(call, attempt: attempt.id, by: attempt.start.replica, in: &transaction)
      }
    },
    ProjectionOperation(name: "record one call on two jobs of a chapter", weight: 5) { generator, _ in
      let (pick, fresh) = (generator.int(in: 0...99), generator.pick(from: JobWorld.calls))
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick), let key = try JobRecords.read(attempt.start.job, in: transaction).record?.request.key else { return }
        let others = try attempts(in: transaction).filter { other in
          guard other.start.job != attempt.start.job, let otherKey = try JobRecords.read(other.start.job, in: transaction).record?.request.key else { return false }
          return otherKey.scope == key.scope && otherKey.target == key.target
        }
        if let named = others.flatMap(\.calls).first(where: { !attempt.calls.contains($0) }) {
          _ = try AttemptRecords.recordCall(named, attempt: attempt.id, by: attempt.start.replica, in: &transaction)
        } else {
          for both in [attempt] + others.filter({ $0.outcome == .running }).prefix(1) {
            _ = try AttemptRecords.recordCall(fresh, attempt: both.id, by: both.start.replica, in: &transaction)
          }
        }
      }
    },
    ProjectionOperation(name: "settle attempt", weight: 4) { generator, _ in
      let pick = generator.int(in: 0...99)
      let settlement = generator.pick(from: [
        AttemptSettlement.succeeded, .failed(AttemptFailure(code: "ai.timeout", message: "The call timed out.")), .stoodDown, .cancelled,
      ])
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick) else { return }
        _ = try AttemptRecords.update(attempt.id, AttemptUpdate(settlement: settlement), by: attempt.start.replica, in: &transaction)
      }
    },
    ProjectionOperation(name: "fail attempt", weight: 3) { generator, _ in
      let pick = generator.int(in: 0...99)
      let failure = AttemptFailure(code: generator.pick(from: ["ai.timeout", "ai.refused"]), message: "The step failed.")
      return { transaction in
        guard let attempt = try running(in: transaction, pick: pick) else { return }
        _ = try AttemptRecords.update(attempt.id, AttemptUpdate(settlement: .failed(failure)), by: attempt.start.replica, in: &transaction)
      }
    },
    ProjectionOperation(name: "write an unreadable attempt", weight: 1) { generator, universe in
      let ref = job(&generator, universe).ref
      let id = try? JobWorld.attemptID(at: seconds(&generator), &generator)
      let start: JSONValue = ["job": .string(ref.key.rawValue), "replica": .string(JobWorld.replicas[0].description), "started": .int(JobWorld.epoch)]
      return { transaction in
        guard let id else { return }
        _ = try transaction.set(id.ref, [AttemptField.start.rawValue: start, AttemptField.lease.rawValue: "lapsed"])
      }
    },
    ProjectionOperation(name: "purge attempt", weight: 1) { generator, _ in
      let pick = generator.int(in: 0...99)
      return { transaction in
        let all = try attempts(in: transaction)
        guard !all.isEmpty else { return }
        _ = try transaction.purge(all[pick % all.count].id.ref)
      }
    },
    ProjectionOperation(name: "purge job", weight: 1) { generator, universe in
      let ref = job(&generator, universe).ref
      return { transaction in _ = try transaction.purge(ref) }
    },
    ProjectionOperation(name: "record a priced call", weight: 4) { generator, _ in
      let (start, events) = (JobWorld.callStart(generator.pick(from: JobWorld.calls)), JobWorld.finishedEvents(Int64(generator.int(in: 1...900))))
      return { transaction in
        guard try transaction.state(of: Ledger.ref(start.id)) == nil else { return }
        try Ledger.begin(start, in: &transaction)
        _ = try Ledger.finish(start, events: events, endedWith: nil, catalog: nil, in: &transaction)
      }
    },
    ProjectionOperation(name: "record a retried call", weight: 2) { generator, _ in
      let (start, events) = (JobWorld.callStart(generator.pick(from: JobWorld.calls)), JobWorld.retriedEvents(Int64(generator.int(in: 1...900))))
      return { transaction in
        guard try transaction.state(of: Ledger.ref(start.id)) == nil else { return }
        try Ledger.begin(start, in: &transaction)
        _ = try Ledger.finish(start, events: events, endedWith: nil, catalog: nil, in: &transaction)
      }
    },
    ProjectionOperation(name: "begin a call", weight: 1) { generator, _ in
      let start = JobWorld.callStart(generator.pick(from: JobWorld.calls))
      return { transaction in
        guard try transaction.state(of: Ledger.ref(start.id)) == nil else { return }
        try Ledger.begin(start, in: &transaction)
      }
    },
    ProjectionOperation(name: "price an abandoned attempt", weight: 3) { generator, _ in
      let (pick, nanoUSD) = (generator.int(in: 0...99), Int64(generator.int(in: 1...90)))
      return { transaction in
        let named = Set(try attempts(in: transaction).flatMap(\.calls))
        let abandoned = try JobWorld.calls.compactMap { call in try abandonedAttempt(of: call, in: transaction).map { (call: call, attempt: $0) } }
        let preferred = abandoned.filter { named.contains($0.call) }
        let candidates = preferred.isEmpty ? abandoned : preferred
        guard !candidates.isEmpty else { return }
        let chosen = candidates[pick % candidates.count]
        try Ledger.reconcile(id: chosen.attempt, cost: Cost(nanoUSD: nanoUSD), in: &transaction)
        if named.contains(chosen.call) { reached("abandoned attempt priced after its call is named") }
      }
    },
    ProjectionOperation(name: "forge a ledger edge", weight: 1) { generator, _ in
      let call = generator.pick(from: JobWorld.calls)
      let other = generator.pick(from: JobWorld.calls.filter { $0 != call })
      let forged = ModelCallEntry(
        id: Ledger.attemptID(of: call, index: 0), provider: "api.example.com", model: "model-a", task: .chat, pace: .steady, startedMillis: JobWorld.epoch,
        parent: other, outcome: .failed, usage: JobWorld.usage, cost: Cost(nanoUSD: Int64(generator.int(in: 1...90))), costSource: .reported)
      return { transaction in
        guard try transaction.state(of: Ledger.ref(forged.id)) == nil else { return }
        try Ledger.open(forged, in: &transaction)
        reached("ledger edge forged")
      }
    },
    ProjectionOperation(name: "purge a ledger entry", weight: 1) { generator, _ in
      let (call, child) = (generator.pick(from: JobWorld.calls), generator.chance(0.5))
      return { transaction in
        let ref = try child ? abandonedAttempt(of: call, in: transaction).map(Ledger.ref) : Ledger.ref(call)
        guard let ref else { return }
        _ = try transaction.purge(ref)
      }
    },
  ]

  private static func abandonedAttempt(of call: UUID, in transaction: borrowing WriteTransaction) throws -> UUID? {
    let id = Ledger.attemptID(of: call, index: 0)
    return try transaction.state(of: Ledger.ref(id)) == nil ? nil : id
  }
}
