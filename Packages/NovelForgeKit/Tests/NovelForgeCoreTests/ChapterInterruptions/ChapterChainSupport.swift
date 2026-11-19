import Foundation
import GRDB
import ShadowAI
import ShadowCore
import ShadowStore
import ShadowTestSupport
import Synchronization
import Testing

@testable import NovelForgeCore
@testable import NovelForgeEval
@testable import ShadowJobs

/// One chapter from plan to canon, in the order nf-eval's `EvalRunner` drives it, with the plan card and the approval as the author makes them.
enum ChainStage: String, CaseIterable, Sendable, Hashable {
  case plan
  case planCard = "plan_card"
  case generate
  case review
  case approve
  case finalizeReview = "finalize_review"
  case keep
  case finalize
  case refresh
}

/// How the chapter is finalized: the commit as the Finalize button makes it, or an `action.finalize` card whose action runs after its content.
enum FinalizePath: Sendable {
  case commit
  case card
}

/// Where a process ends: at an engine or runner crash seam of the stage's job, or between two transactions of the chain.
enum ChainKill: Sendable, Hashable, CustomTestStringConvertible {
  case runner(ChainStage, AttemptRunner.Faults.Point)
  case pinned(ChainStage)
  /// The stages before it committed and this one has written nothing.
  case before(ChainStage)
  /// The routine updates are kept and the consequential one is not answered.
  case routineKept
  /// The finalize card is staged and not applied.
  case cardStaged
  /// The finalize card's content committed and its action did not run.
  case cardContent

  var stage: ChainStage {
    switch self {
    case .runner(let stage, _), .pinned(let stage), .before(let stage): stage
    case .routineKept: .keep
    case .cardStaged, .cardContent: .finalize
    }
  }

  var testDescription: String {
    switch self {
    case .runner(let stage, let point): "\(stage.rawValue) \(point)"
    case .pinned(let stage): "\(stage.rawValue) pinned"
    case .before(let stage): "before \(stage.rawValue)"
    case .routineKept: "routine updates kept"
    case .cardStaged: "finalize card staged"
    case .cardContent: "finalize card content applied"
    }
  }
}

/// Arms one kill, or none, and records every seam the process reaches with the model calls made before it.
final class ChainFaults: Sendable {
  struct Reached: Sendable, Hashable {
    let kill: ChainKill
    let requests: Int
  }

  private struct State {
    var stage = ChainStage.plan
    var fired = false
    var reached: [Reached] = []
  }

  let kill: ChainKill?
  private let requests: @Sendable () -> Int
  private let state = Mutex(State())

  init(kill: ChainKill? = nil, requests: @escaping @Sendable () -> Int = { 0 }) {
    self.kill = kill
    self.requests = requests
  }

  var fired: Bool { state.withLock { $0.fired } }

  var reached: [Reached] { state.withLock { $0.reached } }

  func enter(_ stage: ChainStage) {
    state.withLock { $0.stage = stage }
  }

  var runner: AttemptRunner.Faults {
    AttemptRunner.Faults { [self] point in crashes { .runner($0, point) } }
  }

  var engine: JobEngine.Faults {
    JobEngine.Faults { [self] _ in crashes { .pinned($0) } }
  }

  func crashes(at kill: ChainKill) -> Bool {
    crashes { _ in kill }
  }

  private func crashes(_ seam: (ChainStage) -> ChainKill) -> Bool {
    let count = requests()
    return state.withLock { state in
      let reached = seam(state.stage)
      state.reached.append(Reached(kill: reached, requests: count))
      guard !state.fired, reached == kill else { return false }
      state.fired = true
      return true
    }
  }
}

enum ChainError: Error, CustomStringConvertible {
  case unsettled(EntityRef, AttemptResult)
  case refused(String)

  var description: String {
    switch self {
    case .unsettled(let job, let result): "\(job.key.rawValue) ended \(result)"
    case .refused(let what): what
    }
  }
}

/// The chain's replies in call order: EvalScript's, with a character state the continuity read is unsure of, so the review asks the author and the chapter
/// is finalized by a commit of its own, and a refresh that proposes one Story Bible update, so the refresh stages its card.
enum ChainScript {
  static let chapter = 1
  static let finalizeCard = UUID(uuidString: "6f0c4d1e-0000-4000-8000-0000000000c1") ?? UUID()

  static var continuity: [ScriptedModelProvider.Step] {
    let state: JSONValue = ["entityKey": "mara", "location": "the lighthouse", "evidence": "Mara climbed the lighthouse stairs at dusk", "confidence": "low"]
    return EvalScript.reply([
      "appeared": ["mara"], "newEntities": [], "threads": [], "mysteries": [], "timeline": [], "relationships": [], "power": [], "characterStates": [state],
      "knowledgeChanges": [], "chapterSummary": "Mara finds the logbook torn.", "milestones": [],
    ])
  }

  static var refresh: [ScriptedModelProvider.Step] {
    let update: JSONValue = [
      "finding": "Mara keeps the lighthouse lamp now; her record does not say so.",
      "evidence": [["ref": "chapter:1", "quote": "Mara climbed the lighthouse stairs at dusk with the lamp in her hand"]],
      "changeSet": [["op": "entity.upsert", "entityKey": "mara", "type": "character", "status": "Keeper of the lighthouse lamp."]],
    ]
    return EvalScript.reply(["updates": [update]])
  }

  static var calls: [[ScriptedModelProvider.Step]] {
    Array(EvalScript.calls.prefix(4)) + [continuity, refresh]
  }

  static func name(of request: ModelRequest) -> String {
    guard case .json(let name, _) = request.format else { return "text" }
    return name
  }
}

/// A vault in a file that each process opens afresh, as a relaunched app does, over one model service that outlives the processes.
struct ChainVault: Sendable {
  let url: URL
  let clock = EngineClock()
  let wall = SchemaTestClock()
  let provider: ScriptedModelProvider

  var novel: UUID { EvalFixture.novel }

  static func make(calls: [[ScriptedModelProvider.Step]]) async throws -> ChainVault {
    let vault = ChainVault(
      url: FileManager.default.temporaryDirectory.appending(path: "chain-\(UUID().uuidString)").appending(path: "vault.sqlite"),
      provider: ScriptedModelProvider(calls: calls))
    let process = try vault.open()
    try await EvalFixture.seed(in: process.store)
    try await EvalScript.backend(vault.provider).grantConsent(in: process.store)
    process.end()
    return vault
  }

  func open(_ faults: ChainFaults = ChainFaults()) throws -> ChainProcess {
    clock.advance(5)
    let reconciler = try Projection.reconciler()
    let store = try Projection.store(reconciler, at: .file(url), clock: wall)
    let backend = try EvalScript.backend(provider)
    let lease = LeaseClock(trusted: nil, device: clock.function)
    let (heartbeat, rereads) = (SleepGate(), SleepGate())
    let timing = AttemptRunner.Timing(heartbeat: LeaseTerms.heartbeat) { _ in try await heartbeat.sleep() }
    let engine = try JobEngine(
      store: store, router: { backend.router(store: store, requestGuard: $0) }, consent: EvalBackend.consent, clock: lease,
      runner: AttemptRunner(store: store, clock: lease, timing: timing, faults: faults.runner), timing: JobEngine.Timing { _ in try await rereads.sleep() },
      faults: faults.engine, unrestrictedAvailable: false)
    return ChainProcess(vault: self, store: store, reconciler: reconciler, engine: engine, faults: faults)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}

/// One process on the vault: drives the chain from wherever the vault stands, each stage doing only what is not yet done, as the author would after a relaunch.
struct ChainProcess: Sendable {
  let vault: ChainVault
  let store: VaultStore
  let reconciler: NovelForgeReconciler
  let engine: JobEngine
  let faults: ChainFaults

  var novel: UUID { vault.novel }

  func end() {
    engine.relinquish()
  }

  /// What a launch runs before anything else: the pending-action sweep, then every attempt this device was running, each to its end. False when killed.
  func launch(at stage: ChainStage) async throws -> (swept: [PendingActionResume], finished: Bool) {
    faults.enter(stage)
    let swept = await store.resumePendingActions()
    for handle in try await engine.resumeInterruptedAttempts() {
      guard try await finished(handle) else { return (swept, false) }
    }
    return (swept, true)
  }

  /// True once the chapter's canon is refreshed; false when the armed kill ended the process.
  func drive(_ path: FinalizePath) async throws -> Bool {
    for stage in ChainStage.allCases {
      faults.enter(stage)
      if faults.crashes(at: .before(stage)) { return false }
      guard try await perform(stage, path) else { return false }
    }
    return true
  }

  private func perform(_ stage: ChainStage, _ path: FinalizePath) async throws -> Bool {
    let (novel, chapter) = (novel, ChainScript.chapter)
    switch stage {
    case .plan:
      if let job = try await job(.plan) { return try await settle(job) }
      return try await settle(try await engine.requestPlan(ChapterPlanJobRequest(novel: novel)).job.ref)
    case .planCard:
      let card = PlanCards.id(of: try #require(try await job(.plan)))
      if try await decision(card) == .known(.applied) { return true }
      guard try await NovelEvaluation.applyPlanCard(of: try #require(try await job(.plan)), novel: novel, in: store, now: vault.clock.now) else {
        throw ChainError.refused("the plan card conflicted")
      }
      return true
    case .generate:
      if let job = try await job(.generate) { return try await settle(job) }
      let started: StartedGeneration
      do throws(GenerationRequestError) {
        started = try await engine.generateChapter(novel: novel, chapter: chapter)
      } catch .engine(.run(.interrupted)) where faults.fired {
        return false
      }
      guard case .running(let handle) = started else { throw ChainError.refused("generate ran elsewhere") }
      return try await finished(handle)
    case .review:
      if let job = try await job(.review) { return try await settle(job) }
      let started: StartedReview
      do throws(ReviewRequestError) {
        started = try await engine.requestReview(novel: novel, chapter: chapter, kind: .judge)
      } catch .engine(.run(.interrupted)) where faults.fired {
        return false
      }
      guard case .running(let handle) = started else { throw ChainError.refused("the judge review did not run as a job") }
      return try await finished(handle)
    case .approve:
      if try await approved() { return true }
      let ref = try DraftRecord.ref(novel: novel, chapter: chapter)
      let head = try #require(try await store.read { transaction in try DraftRecord.history(ref, in: transaction).history?.head })
      _ = try await store.approveChapter(novel: novel, chapter: chapter, revision: head)
      return true
    case .finalizeReview:
      return try await settle(try #require(try await store.finalizeReviewJob(novel: novel, chapter: chapter)))
    case .keep:
      if try await isFinal() { return true }
      try await store.keepRoutineFinalizeItems(novel: novel, chapter: chapter)
      if faults.crashes(at: .routineKept) { return false }
      for item in try await unanswered() { try await store.decideFinalizeItem(novel: novel, chapter: chapter, item: item, decision: .kept) }
      return true
    case .finalize:
      if try await isFinal() { return true }
      switch path {
      case .commit: try await store.write { transaction in _ = try ChapterFinalize.finalize(novel: novel, chapter: chapter, in: &transaction) }
      case .card: guard try await finalizeByCard() else { return false }
      }
      return try await isFinal()
    case .refresh:
      return try await settle(try #require(try await job(.canonRefresh)))
    }
  }

  private func finalizeByCard() async throws -> Bool {
    let (card, novel) = (ChainScript.finalizeCard, novel)
    if case .absent = try await store.read({ transaction in try ProposalRecord.read(id: card, in: transaction) }) {
      let changeSet = try StagingWorld.changeSet(#"{"op":"action.finalize","upTo":1}"#)
      try await store.write { transaction in _ = try ProposalStager.stage(StagingWorld.input(changeSet, novel: novel, session: nil), id: card, in: &transaction) }
    }
    if faults.crashes(at: .cardStaged) { return false }
    let context = ProposalApplyContext(novel: novel, now: vault.clock.now)
    if faults.crashes(at: .cardContent) {
      _ = try await store.write { transaction in try ProposalApply.apply(proposal: card, selection: .indexes([0]), context: context, in: &transaction) }
      return false
    }
    guard case .applied(let changes) = try await store.applyProposal(card, selection: .indexes([0]), context: context), changes.map(\.status) == [.applied] else {
      throw ChainError.refused("the finalize card's action did not apply")
    }
    return true
  }

  private func settle(_ job: EntityRef) async throws -> Bool {
    if case .succeeded = try await status(job) { return true }
    let handle: JobRunHandle
    do throws(JobEngineError) {
      handle = try await engine.run(job: job)
    } catch .run(.interrupted) where faults.fired {
      return false
    }
    return try await finished(handle)
  }

  private func finished(_ handle: JobRunHandle) async throws -> Bool {
    let result = await handle.result
    if result == .settled(.succeeded) { return true }
    guard result == .interrupted, faults.fired else { throw ChainError.unsettled(handle.job, result) }
    return false
  }
}

extension ChainProcess {
  func jobs() async throws -> [JobRecord] {
    let scope = NovelJobAddress.scope(of: novel)
    return try await store.read { transaction in
      try transaction.states(ofKind: JobSchema.jobKind).compactMap { JobRecords.reading($0.state, of: $0.ref).record }.filter { $0.request.key.scope == scope }
    }
  }

  func job(_ kind: NovelJobKind) async throws -> EntityRef? {
    let matching = try await jobs().filter { $0.request.key.kind == kind.rawValue }
    guard matching.count <= 1 else { throw ChainError.refused("\(matching.count) \(kind.rawValue) jobs") }
    return matching.first?.ref
  }

  func snapshot(_ job: EntityRef) async throws -> JobSnapshot {
    try #require(try await store.read { transaction in try JobSnapshot.load(job, in: transaction) })
  }

  func status(_ job: EntityRef) async throws -> JobStatus {
    JobStatus(try await snapshot(job), at: vault.clock.instant)
  }

  func decision(_ proposal: UUID) async throws -> StoredEnum<ProposalDecision>? {
    try await store.read { transaction in try ProposalRecord.read(id: proposal, in: transaction).entry?.record.decision }
  }

  func chapter() async throws -> EvaluationChapter? {
    try await NovelEvaluation.chapters(novel: novel, in: store).chapters.first { $0.chapter == ChainScript.chapter }
  }

  func approved() async throws -> Bool {
    try await chapter()?.approved == true
  }

  func isFinal() async throws -> Bool {
    try await chapter()?.status == "final"
  }

  func unanswered() async throws -> [String] {
    let (novel, chapter) = (novel, ChainScript.chapter)
    return try await store.read { transaction in
      let answered = Set(try FinalizeDecisionRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.map(\.record.item))
      let items = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).records.flatMap(\.items)
      return items.filter { $0.triage == .known(.consequential) && !answered.contains($0.key) }.map(\.key)
    }
  }

  func ledger() async throws -> [UUID] {
    try await store.read { transaction in try Ledger.entries(in: transaction) }.filter { $0.parent == nil }.map(\.id)
  }

  func localRows() async throws -> [String: Int] {
    try await store.read { transaction in
      let database = transaction.database
      let tables = try String.fetchAll(
        database, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'nf\\_local\\_%' ESCAPE '\\' OR name LIKE 'jobs\\_local\\_%' ESCAPE '\\')")
      var rows: [String: Int] = [:]
      for table in tables { rows[table] = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
      return rows
    }
  }

  /// Changes the unsent log holds per kind; the job and ledger kinds, which a resume writes to again by design, are left out.
  func changes() async throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for change in try await store.pendingChanges(limit: Int.max) {
      let kind = try ChangeRecord(json: try CanonicalJSON.decode(change.line)).ref.kind.rawValue
      guard !kind.hasPrefix("jobs_"), !kind.hasPrefix("ai_") else { continue }
      counts[kind, default: 0] += 1
    }
    return counts
  }

  func footprint() async throws -> ChainFootprint {
    let (novel, chapter) = (novel, ChainScript.chapter)
    let jobs = try await jobs().map { "\($0.request.key.kind) run=\($0.request.key.run)" }.sorted()
    let read = try await store.read { transaction in
      let drafts = try DraftRecord.history(try DraftRecord.ref(novel: novel, chapter: chapter), in: transaction).history?.revisions.compactMap { $0.body.body?.body } ?? []
      let plans = try ChapterPlanRecord.history(try ChapterPlanRecord.ref(novel: novel, chapter: chapter), in: transaction).history?.revisions.count ?? 0
      let finals = try transaction.states(ofKind: FinalChapterRecord.kind.entityKind, scope: .vault).count
      let reviews = try ChapterReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).entries.map(\.record).map { review in
        "\(review.reviewKind.rawValue) pass=\(review.generationPass) verdict=\(review.verdict ?? "-")"
      }
      let finalizeReviews = try FinalizeReviewRecord.listing(novel: novel, chapter: chapter, in: transaction).records.map { $0.items.map(\.key).joined(separator: ",") }
      let reports = try RefreshReportRecord.listing(novel: novel, chapter: chapter, in: transaction).records.map { $0.proposal != nil }
      let proposals = try ProposalRecord.listing(in: transaction).entries.map(\.record).map { "\($0.card.kind.rawValue) \($0.decision.rawValue)" }
      return (drafts, plans, finals, reviews.sorted(), finalizeReviews, reports, proposals.sorted())
    }
    return ChainFootprint(
      drafts: read.0, plans: read.1, finals: read.2, reviews: read.3, finalizeReviews: read.4, reportsNameCards: read.5, proposals: read.6, jobs: jobs,
      changes: try await changes(), localRows: try await localRows())
  }
}

/// What the chain left in the vault, without ids or times: a resumed chain leaves the footprint of one that never stopped.
struct ChainFootprint: Sendable, Equatable {
  let drafts: [String]
  let plans: Int
  let finals: Int
  let reviews: [String]
  let finalizeReviews: [String]
  let reportsNameCards: [Bool]
  let proposals: [String]
  let jobs: [String]
  let changes: [String: Int]
  let localRows: [String: Int]
}

/// The uninterrupted chain: every seam it reaches, the calls it makes, the replies they take and what it leaves.
struct ChainRecording: Sendable {
  let path: FinalizePath
  let reached: [ChainFaults.Reached]
  let names: [String]
  let footprint: ChainFootprint

  static let commit = Task { try await record(.commit) }
  static let card = Task { try await record(.card) }

  static func recording(_ path: FinalizePath) async throws -> ChainRecording {
    switch path {
    case .commit: try await commit.value
    case .card: try await card.value
    }
  }

  private static func record(_ path: FinalizePath) async throws -> ChainRecording {
    let vault = try await ChainVault.make(calls: ChainScript.calls)
    defer { vault.remove() }
    let provider = vault.provider
    let process = try vault.open(ChainFaults { provider.requests.count })
    guard try await process.drive(path) else { throw ChainError.refused("the uninterrupted chain stopped") }
    return ChainRecording(path: path, reached: process.faults.reached, names: provider.requests.map(ChainScript.name), footprint: try await process.footprint())
  }

  var kills: [ChainKill] {
    var seen = Set<ChainKill>()
    return reached.map(\.kill).filter { seen.insert($0).inserted }
  }

  /// The calls the kill loses: those of the step it ended inside or before its commit, which the resumed step sends again.
  func lost(_ kill: ChainKill) -> Range<Int>? {
    guard case .runner(let stage, let point) = kill else { return nil }
    let step: Int
    switch point {
    case .call(let index), .beforeCommit(let index): step = index
    default: return nil
    }
    let seams = reached.filter { $0.kill.stage == stage }
    guard let first = seams.firstIndex(where: { [.runner(stage, .call(step: step)), .runner(stage, .beforeCommit(step: step))].contains($0.kill) }), first > 0,
      let end = seams.first(where: { $0.kill == .runner(stage, .beforeCommit(step: step)) })
    else { return nil }
    let calls = seams[first - 1].requests..<end.requests
    return calls.isEmpty ? nil : calls
  }

  /// The uninterrupted calls with each lost step's calls sent again after it, once per kill that lost them.
  func calls(losing kills: [ChainKill]) -> [Int] {
    let lost = kills.compactMap(lost)
    return names.indices.flatMap { index in [index] + lost.filter { $0.last == index }.flatMap { Array($0) } }
  }
}

/// The chain run on a vault of its own, each kill ending a process and a new process launching after it, until one runs to the refreshed canon.
struct ChainRun: Sendable {
  let vault: ChainVault
  let last: ChainProcess
  let sweeps: [[PendingActionResume]]

  static func run(_ kills: [ChainKill], path: FinalizePath, sourceLocation: SourceLocation = #_sourceLocation) async throws -> ChainRun {
    let recording = try await ChainRecording.recording(path)
    let vault = try await ChainVault.make(calls: recording.calls(losing: kills).map { ChainScript.calls[$0] })
    var (sweeps, stage) = ([[PendingActionResume]](), ChainStage.plan)
    for (index, kill) in (kills.map(Optional.some) + [nil]).enumerated() {
      let process = try vault.open(ChainFaults(kill: kill))
      var finished = true
      if index > 0 {
        let launched = try await process.launch(at: stage)
        sweeps.append(launched.swept)
        finished = launched.finished
      }
      if finished { finished = try await process.drive(path) }
      guard let kill else {
        #expect(finished, "the last process runs the chain to its end", sourceLocation: sourceLocation)
        return ChainRun(vault: vault, last: process, sweeps: sweeps)
      }
      #expect(!finished && process.faults.fired, "\(kill.testDescription) ends its process", sourceLocation: sourceLocation)
      process.end()
      stage = kill.stage
    }
    preconditionFailure("the loop returns at its last process")
  }

  /// The chapter final once, each record of the chain written once, the calls the kills lost sent again and no other, every call on an attempt, the
  /// derived tables a rebuild's, and nothing left beside the vault.
  func expectCanon(losing kills: [ChainKill], path: FinalizePath, sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let recording = try await ChainRecording.recording(path)
    let footprint = try await last.footprint()
    #expect(try await last.isFinal(), sourceLocation: sourceLocation)
    #expect(footprint == recording.footprint, sourceLocation: sourceLocation)
    #expect(footprint.finals == 1 && footprint.changes["nf_final_chapter"] == 1, "one canon", sourceLocation: sourceLocation)
    #expect(footprint.finalizeReviews.count == 1, "one finalize review", sourceLocation: sourceLocation)
    #expect(footprint.reportsNameCards == [true] && footprint.proposals.count { $0.hasPrefix("bible_audit") } == 1, "one report and its card", sourceLocation: sourceLocation)
    #expect(footprint.reviews == ["judge pass=false verdict=consistent", "judge pass=true verdict=consistent"], sourceLocation: sourceLocation)
    let plan = try #require(try await last.job(.plan), sourceLocation: sourceLocation)
    #expect(try await last.decision(PlanCards.id(of: plan)) == .known(.applied), sourceLocation: sourceLocation)
    #expect(footprint.plans == 1 && footprint.proposals.count { $0.hasPrefix("chapter_plan") } == 1, "the plan card applied once", sourceLocation: sourceLocation)

    let provider = vault.provider
    #expect(provider.requests.map(ChainScript.name) == recording.calls(losing: kills).map { recording.names[$0] }, sourceLocation: sourceLocation)
    #expect(provider.remainingCalls == 0, sourceLocation: sourceLocation)
    var calls: [UUID] = []
    for job in try await last.jobs() {
      let snapshot = try await last.snapshot(job.ref)
      #expect(snapshot.attempts.count == 1, "\(job.request.key.kind) resumes its one attempt", sourceLocation: sourceLocation)
      guard case .succeeded = JobStatus(snapshot, at: vault.clock.instant) else {
        Issue.record("\(job.request.key.kind) did not succeed", sourceLocation: sourceLocation)
        continue
      }
      calls += snapshot.attempts.flatMap(\.calls)
    }
    let ledger = try await last.ledger()
    #expect(ledger.count == provider.requests.count && Set(ledger).count == ledger.count, sourceLocation: sourceLocation)
    #expect(calls.count == ledger.count && Set(calls) == Set(ledger), "ledger entries are the attempts' calls", sourceLocation: sourceLocation)

    let comparison = try await Projection.compare(last.reconciler, in: last.store)
    #expect(comparison.incremental == comparison.rebuilt, sourceLocation: sourceLocation)
    #expect((comparison.incremental[last.reconciler.faultTable] ?? []).isEmpty, sourceLocation: sourceLocation)
    let orphans = footprint.localRows.filter { $0.key != WriterSnapshots.table && $0.value > 0 }
    #expect(orphans.isEmpty, "rows left beside the vault: \(orphans)", sourceLocation: sourceLocation)
  }
}
