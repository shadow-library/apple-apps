import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowTestSupport
import Testing

@testable import NovelForgeCore
@testable import NovelForgeEval
@testable import ShadowJobs

/// A device as its replica directory entry names it.
struct HandOffRole: Sendable {
  let name: String
  let platform: String

  static let phone = HandOffRole(name: "Pocket iPhone", platform: "iOS")

  static func mac(_ name: String = "Studio Mac") -> HandOffRole {
    HandOffRole(name: name, platform: "macOS")
  }
}

/// Devices on one vault that sync only when a test delivers, the evaluation fixture's novel seeded, each device's consent granted and its directory entry
/// declared. Device `i`'s clocks run `ahead[i]` seconds ahead (10 s per index unless given), so a later device's attempts start later.
struct HandOffWorld: Sendable {
  let reconciler: NovelForgeReconciler
  let replicas: CausalReplicas
  let devices: [ChapterDevice]
  let roles: [HandOffRole]

  static func make(_ roles: [HandOffRole], seed: UInt64, ahead: [Int]? = nil) async throws -> HandOffWorld {
    let reconciler = try Projection.reconciler()
    let replicas = try await CausalReplicas(
      CausalReplicaSetup(
        count: roles.count, registry: Projection.registry, migrations: reconciler.migrations, order: .causal, reconciler: { _ in reconciler }, seed: seed))
    let novel = ChapterReplicas.novel
    _ = try await replicas.write(0) { transaction in
      _ = try NovelRecord(id: novel, name: "The Lighthouse", wordTarget: EvalFixture.wordTarget).create(in: &transaction)
      _ = try EntityRecord(novel: novel, entity: "mara", type: .known(.character), name: "Mara").create(in: &transaction)
      _ = try ThreadRecord(novel: novel, thread: "lamp", summary: "What the lamp shows", openedChapter: 1, status: ThreadProgress(state: .known(.open)))
        .create(in: &transaction)
    }
    var devices = [ChapterDevice]()
    for (index, role) in roles.enumerated() {
      let (consent, replica) = (CompactionWorld.consent, await replicas.store(index).replica)
      _ = try await replicas.write(index) { transaction in
        for host in ["api.example.com", "router.example.com"] {
          try AIConsent.decide(.granted, provider: host, dataClass: consent.dataClass, summary: consent.disclosure, atMillis: 1, in: &transaction)
        }
        try ReplicaDirectory.declareActive(replica, name: role.name, platform: role.platform, createdMillis: 1, in: &transaction)
      }
      devices.append(ChapterDevice(index: index, store: await replicas.store(index)))
    }
    try await replicas.settle()
    let world = HandOffWorld(reconciler: reconciler, replicas: replicas, devices: devices, roles: roles)
    for index in roles.indices { await world.advance(index, by: ahead?[index] ?? index * 10) }
    return world
  }

  subscript(_ index: Int) -> ChapterDevice { devices[index] }

  func device(_ index: Int, seenFrom observer: Int) -> JobDevice {
    JobDevice(replica: devices[index].replica, name: roles[index].name, isHere: index == observer)
  }

  func ship(_ index: Int) async throws {
    _ = try await replicas.write(index) { _ in }
  }

  func deliver(from writer: Int, to reader: Int) async throws {
    try await ship(writer)
    _ = try await replicas.deliver(from: writer, to: reader)
  }

  func sync() async throws {
    for index in devices.indices { try await ship(index) }
    try await replicas.settle()
  }

  func advance(_ index: Int, by seconds: Int) async {
    devices[index].clock.advance(TimeInterval(seconds))
    await replicas.advanceClock(of: index, by: .seconds(seconds))
  }

  /// Every device holds one vault, derives the same tables a rebuild derives, keeps a consistent ledger and leaves no run or row of its own behind;
  /// `cutCalls` is how many calls an interruption cut that a succeeded attempt sent again.
  func expectConverged(cutCalls: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await sync()
    let digest = try await devices[0].store.loadState(.vault).digest
    let tables = try await Projection.derived(reconciler, in: devices[0].store)
    for device in devices {
      #expect(try await device.store.loadState(.vault).digest == digest, "replica \(device.index) holds another vault state", sourceLocation: sourceLocation)
      let comparison = try await Projection.compare(reconciler, in: device.store)
      let differing = comparison.incremental.keys.filter { comparison.incremental[$0] != comparison.rebuilt[$0] }.sorted()
      #expect(differing.isEmpty, "replica \(device.index) is not a rebuild: \(differing)", sourceLocation: sourceLocation)
      #expect((comparison.incremental[reconciler.faultTable] ?? []).isEmpty, "replica \(device.index) holds faults", sourceLocation: sourceLocation)
      let derived = try await Projection.derived(reconciler, in: device.store)
      let diverged = Set(tables.keys).union(derived.keys).filter { derived[$0] != tables[$0] }.sorted()
      #expect(diverged.isEmpty, "replica \(device.index) derives other tables: \(diverged)", sourceLocation: sourceLocation)
      try await HandOffLedger.expectConsistent(device.store, replica: device.index, cutCalls: cutCalls, sourceLocation: sourceLocation)
      #expect(try await device.engine.interruptedRuns().isEmpty, "replica \(device.index) holds a run to resume", sourceLocation: sourceLocation)
      let orphans = try await HandOffFootprint.localRows(device.store).filter { $0.key != WriterSnapshots.table && $0.value > 0 }
      #expect(orphans.isEmpty, "replica \(device.index) left rows beside the vault: \(orphans)", sourceLocation: sourceLocation)
    }
  }

  func expectSameWorkAsOneDevice(through stage: ChapterStage, cutCalls: Int = 0, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    try await expectConverged(cutCalls: cutCalls, sourceLocation: sourceLocation)
    let expected = try #require(try await HandOffBaseline.recording.value.footprints[stage], sourceLocation: sourceLocation)
    for device in devices {
      #expect(try await HandOffFootprint.read(device) == expected, "replica \(device.index)", sourceLocation: sourceLocation)
    }
  }
}

enum HandOffLedger {
  /// `ChapterLedger`'s rules, except that a succeeded attempt keeps open the calls an interruption cut: an aborted call stays begun by design
  /// (LedgeredProvider), and an attempt interrupted mid-call and resumed sends it again and succeeds.
  static func expectConsistent(_ store: VaultStore, replica index: Int, cutCalls: Int, sourceLocation: SourceLocation) async throws {
    let (entries, attempts) = try await store.read { transaction in
      let attempts = try transaction.states(ofKind: JobSchema.attemptKind).compactMap { AttemptRecords.reading($0.state, of: $0.ref).record }
      return (try Ledger.entries(in: transaction), attempts)
    }
    let calls = Set(entries.filter { $0.parent == nil }.map(\.id))
    let claimed = attempts.flatMap(\.calls)
    #expect(Set(claimed).count == claimed.count, "replica \(index): a call is claimed by two attempts", sourceLocation: sourceLocation)
    #expect(Set(claimed) == calls, "replica \(index): the ledger's calls \(calls.count) are not the attempts' \(claimed.count)", sourceLocation: sourceLocation)
    let succeeded = Set(attempts.filter { $0.outcome == .succeeded }.flatMap(\.calls))
    let open = entries.filter { succeeded.contains($0.parent ?? $0.id) && $0.outcome == .started }
    #expect(open.count == cutCalls, "replica \(index): succeeded attempts left \(open.count) calls open", sourceLocation: sourceLocation)
  }
}

extension ChapterStage {
  /// Asks for the stage's job as the app asks on a device that leaves the worker's kinds to the worker: nothing is started here.
  func request(on device: ChapterDevice) async throws -> EntityRef {
    let (engine, novel, chapter) = (try device.engine, ChapterReplicas.novel, Self.chapter)
    switch self {
    case .plan:
      return try await engine.requestPlan(ChapterPlanJobRequest(novel: novel)).job.ref
    case .generate:
      return try await engine.requestGeneration(novel: novel, chapter: chapter).ref
    case .review:
      guard case .requested(let key) = try await engine.queueReview(novel: novel, chapter: chapter, kind: .judge) else {
        throw EngineFixtureError(description: "the judge review answered at once")
      }
      return key.ref
    case .finalizeReview:
      _ = try await device.store.approveChapter(novel: novel, chapter: chapter, revision: try await device.head())
      return try #require(try await device.store.finalizeReviewJob(novel: novel, chapter: chapter))
    case .canonRefresh:
      return try await engine.requestCanonRefresh(novel: novel, chapter: chapter).ref
    }
  }

  var kind: NovelJobKind {
    switch self {
    case .plan: .plan
    case .generate: .generate
    case .review: .review
    case .finalizeReview: .finalizeReview
    case .canonRefresh: .canonRefresh
    }
  }
}

extension ChapterDevice {
  func backlog() async throws -> WorkerBacklog {
    try await store.load(WorkerBacklog.self, WorkerBacklogQuery(replica: replica, now: clock.instant))
  }

  func placement(of job: EntityRef) async throws -> JobPlacement? {
    try await store.load(JobPlacements.self, JobPlacementQuery(jobs: [job], replica: replica, now: clock.instant)).placement(of: job)
  }

  /// What a worker's runtime does with the backlog: when it names this replica the worker, starts each job it lists automatically, in its order.
  func drain() async throws -> [JobRunHandle] {
    let backlog = try await backlog()
    guard backlog.isWorkerHere else { return [] }
    var handles = [JobRunHandle]()
    for entry in try #require(backlog.jobs.value) { handles.append(try await engine.run(job: entry.job)) }
    return handles
  }

  func drainToEnd(_ job: EntityRef, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JobRunHandle {
    let handles = try await drain()
    #expect(handles.map(\.job) == [job], "replica \(index) drained \(handles.map(\.job))", sourceLocation: sourceLocation)
    let handle = try #require(handles.first, sourceLocation: sourceLocation)
    #expect(await handle.result == .settled(.succeeded), sourceLocation: sourceLocation)
    return handle
  }

  func attempts(_ job: EntityRef) async throws -> [AttemptRecord] {
    try await snapshot(job).attempts
  }
}

extension HandOffWorld {
  /// One stage as decision 1 places it: `requester` asks, reads it queued for itself (a plan) or for `worker`, and starts nothing of the worker's kinds; a plan
  /// runs there, any other kind on the worker once the request reached it, while each of `bystanders` drains nothing; the requester then completes it as the
  /// author does (the plan card applied, the chapter finalized), and every device syncs.
  @discardableResult
  func handOff(
    _ stage: ChapterStage, requester: Int = 0, worker: Int, bystanders: [Int] = [], sourceLocation: SourceLocation = #_sourceLocation
  ) async throws -> EntityRef {
    let asker = self[requester]
    let sent = asker.model.requests
    let job = try await stage.request(on: asker)
    let waitingFor: JobWaitingFor = stage.kind.queuesForWorker ? .worker(.named(device(worker, seenFrom: requester))) : .requester(device(requester, seenFrom: requester))
    guard case .queued(let queued)? = try await asker.placement(of: job) else {
      Issue.record("\(stage) is not queued on its requester", sourceLocation: sourceLocation)
      return job
    }
    #expect(queued.waitingFor == waitingFor && queued.latest == nil, "\(stage) waits for \(queued.waitingFor)", sourceLocation: sourceLocation)
    if stage.kind.queuesForWorker {
      #expect(try await asker.drain().isEmpty && asker.model.requests == sent, "the requester starts no \(stage)", sourceLocation: sourceLocation)
      try await sync()
      for bystander in bystanders {
        #expect(try await self[bystander].backlog().jobs.value?.map(\.job) == [job], sourceLocation: sourceLocation)
        #expect(try await self[bystander].drain().isEmpty, "replica \(bystander) is no worker and drains nothing", sourceLocation: sourceLocation)
      }
      self[worker].model.queue(stage.calls())
      _ = try await self[worker].drainToEnd(job, sourceLocation: sourceLocation)
    } else {
      #expect(try await asker.backlog().jobs.value?.contains { $0.job == job } == false, "a plan never queues for the worker", sourceLocation: sourceLocation)
      asker.model.queue(stage.calls())
      #expect(await (try await asker.engine.run(job: job)).result == .settled(.succeeded), sourceLocation: sourceLocation)
    }
    try await sync()
    try await stage.complete(on: asker, job: job)
    try await sync()
    return job
  }
}

/// What the chapter's work left in the vault, read the same on every replica and without ids, times or attempts: work handed between devices leaves the
/// footprint of the same work done on one.
struct HandOffFootprint: Sendable, Equatable {
  let drafts: [String]
  let head: String?
  let plans: Int
  let finals: Int
  let canon: Bool
  let reviews: [String]
  let finalizeReviews: [String]
  let reportsNameCards: [Bool]
  let proposals: [String]
  let jobs: [String]
  /// Records per Novel Forge kind, empty kinds left out.
  let records: [String: Int]

  static func read(_ device: ChapterDevice) async throws -> HandOffFootprint {
    let (novel, chapter) = (ChapterReplicas.novel, ChapterStage.chapter)
    return try await device.store.read { transaction in
      let history = try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: transaction).history
      let drafts = history?.revisions.compactMap { $0.body.body?.body } ?? []
      let head = history.flatMap { history in history.revisions.first { $0.id == history.head }?.body.body?.body }
      let plans = try ChapterPlanRecord.history(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).history?.revisions.count ?? 0
      let finalRef = try FinalChapterRecord.ref(novel: novel, chapter: chapter)
      let canon = FinalChapterRecord.reading(try transaction.state(of: finalRef, scope: .vault), of: finalRef).entry?.record.canon != nil
      let reviews = try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.map(\.record).map { review in
        "\(review.reviewKind.rawValue) pass=\(review.generationPass) verdict=\(review.verdict ?? "-")"
      }
      let finalizeReviews = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).records.map { $0.items.map(\.key).joined(separator: ",") }
      let reports = try RefreshReportRecord.listing(novel: novel, chapter: chapter, in: transaction).records.map { $0.proposal != nil }
      let proposals = try ProposalRecord.listing(in: transaction).entries.map(\.record).map { "\($0.card.kind.rawValue) \($0.decision.rawValue)" }
      let jobs = try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }
        .map { "\($0.request.key.kind) run=\($0.request.key.run)" }
      var records: [String: Int] = [:]
      for kind in NovelForgeKind.allCases {
        let count = try transaction.states(ofKind: kind.entityKind).count
        if count > 0 { records[kind.rawValue] = count }
      }
      return HandOffFootprint(
        drafts: drafts, head: head, plans: plans, finals: try transaction.states(ofKind: FinalChapterRecord.kind.entityKind, scope: .vault).count, canon: canon,
        reviews: reviews.sorted(), finalizeReviews: finalizeReviews, reportsNameCards: reports, proposals: proposals.sorted(), jobs: jobs.sorted(), records: records)
    }
  }

  static func localRows(_ store: VaultStore) async throws -> [String: Int] {
    try await store.read { transaction in
      let database = transaction.database
      let tables = try String.fetchAll(
        database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'nf\\_local\\_%' ESCAPE '\\' OR name LIKE 'jobs\\_local\\_%' ESCAPE '\\')")
      var rows: [String: Int] = [:]
      for table in tables { rows[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
      return rows
    }
  }
}

/// The chapter's work done on one device, each job run there as soon as it is asked for: the footprint after each stage and the calls each stage sends.
struct HandOffBaseline: Sendable {
  let footprints: [ChapterStage: HandOffFootprint]
  let calls: [ChapterStage: [String]]

  static let recording = Task { try await record() }

  private static func record() async throws -> HandOffBaseline {
    let world = try await HandOffWorld.make([.phone], seed: 0x4805)
    let device = world[0]
    var (footprints, calls) = ([ChapterStage: HandOffFootprint](), [ChapterStage: [String]]())
    for stage in ChapterStage.allCases {
      let sent = device.model.requests
      let job = try await stage.request(on: device)
      device.model.queue(stage.calls())
      let result = await (try await device.engine.run(job: job)).result
      guard result == .settled(.succeeded) else { throw EngineFixtureError(description: "the one-device \(stage) ended \(result)") }
      try await stage.complete(on: device, job: job)
      footprints[stage] = try await HandOffFootprint.read(device)
      calls[stage] = device.model.scripted.requests.dropFirst(sent).map(ChainScript.name)
    }
    return HandOffBaseline(footprints: footprints, calls: calls)
  }
}
