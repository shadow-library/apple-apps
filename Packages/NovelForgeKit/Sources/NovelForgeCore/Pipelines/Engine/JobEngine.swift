import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import Synchronization

/// A request for a novel's job. The same request made on two devices is one job (plan, Jobs and attempts); `rerun` asks for the next run of it, as a
/// regenerate does (orchestrator decision 8: re-run = highest run + 1). `rerunOnceSucceeded` asks for the next run only when the highest has succeeded, decided
/// in the request's own write, so asks made together share one run, as a review asked again after it was stored does.
public struct NovelJobRequest: Sendable, Hashable {
  public let kind: NovelJobKind
  public let novel: UUID
  public let chapter: Int
  public let fingerprint: String
  public let payload: JSONValue
  public let origin: JSONValue
  public let rerun: Bool
  public let rerunOnceSucceeded: Bool

  public init(
    kind: NovelJobKind, novel: UUID, chapter: Int, fingerprint: String, payload: JSONValue = .null, origin: JSONValue = .null, rerun: Bool = false,
    rerunOnceSucceeded: Bool = false
  ) {
    self.kind = kind
    self.novel = novel
    self.chapter = chapter
    self.fingerprint = fingerprint
    self.payload = payload
    self.origin = origin
    self.rerun = rerun
    self.rerunOnceSucceeded = rerunOnceSucceeded
  }
}

public struct JobRunHandle: Sendable {
  public let job: EntityRef
  public let attempt: AttemptID
  let handle: AttemptHandle
  let ended: @Sendable () async -> Void

  /// Once the run ends, after what this device kept for it alone is cleared.
  public var result: AttemptResult {
    get async {
      let result = await handle.result
      await ended()
      return result
    }
  }
}

/// Runs this vault's jobs on this device: one engine, and so one `AttemptRunner`, per vault, since the runner's running set is what keeps a second attempt of
/// a job from starting here. Whether an attempt may run is decided from `JobSnapshot` and `AttemptVerdict`, never from derived tables; the runner's watcher
/// re-reads the job after every commit, remote applies included, and stands the attempt down (plan, Leases, stopping and resuming).
public final class JobEngine: Sendable {
  static let logger = Logger(category: "jobs.engine")

  /// Builds a router for one step whose request guard is the one given: the engine's, with the novel's live minor characters.
  public typealias RouterSource = @Sendable (_ requestGuard: @escaping @Sendable (ModelRoute) -> ModelRequestGuard?) async -> TaskRouter

  struct Timing: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void

    static let standard = Timing { try await Task.sleep(for: $0) }
  }

  /// Where a start can be made to end as a crash ends it; the runner's own `Faults` cover every write after the start.
  struct Faults: Sendable {
    enum Point: Sendable, Hashable {
      /// The pins are read and the attempt is not started.
      case pinned
    }

    let crashes: @Sendable (Point) -> Bool

    static let none = Faults { _ in false }
  }

  let store: VaultStore
  let runner: AttemptRunner
  let clock: LeaseClock
  let services: JobServices
  let catalog: @Sendable (NovelJobKind) -> NovelPipelineDefinition
  let timing: Timing
  let faults: Faults
  private let handles = Mutex<[AttemptID: JobRunHandle]>([:])
  private let starting = Mutex<[EntityRef: Task<Result<JobRunHandle, JobEngineError>, Never>]>([:])
  private let claim: JobEngineClaim

  /// `embedders` ranks the plan's retrieval by vectors too once a novel is fully embedded; without it the plan's retrieval is full-text alone.
  public convenience init(
    store: VaultStore, router: @escaping RouterSource, consent: AIConsentRequirement, clock: LeaseClock, embedders: (any EmbedderProvider)? = nil,
    unrestrictedAvailable: Bool = UnrestrictedWriting.isAvailable
  ) throws(JobEngineError) {
    try self.init(
      store: store, router: router, consent: consent, clock: clock, runner: AttemptRunner(store: store, clock: clock), embedders: embedders,
      unrestrictedAvailable: unrestrictedAvailable)
  }

  init(
    store: VaultStore, router: @escaping RouterSource, consent: AIConsentRequirement, clock: LeaseClock, runner: AttemptRunner,
    catalog: @escaping @Sendable (NovelJobKind) -> NovelPipelineDefinition = PipelineCatalog.definition(for:), packs: WriterPackBuilder? = nil,
    embedders: (any EmbedderProvider)? = nil, timing: Timing = .standard, faults: Faults = .none, unrestrictedAvailable: Bool = UnrestrictedWriting.isAvailable
  ) throws(JobEngineError) {
    claim = try JobEngineClaim(store)
    self.store = store
    self.runner = runner
    self.clock = clock
    self.catalog = catalog
    self.timing = timing
    self.faults = faults
    let packs = packs ?? vaultWriterPack(store)
    services = JobServices(
      store: store, router: router, consent: consent, unrestrictedAvailable: unrestrictedAvailable, hardLines: NovelHardLines(), packs: packs,
      retrieval: NovelRetrieval(store: store, embedders: embedders), now: { clock.now().date })
  }

  deinit {
    claim.release()
  }

  /// Gives the vault up as a process that ended does, so another engine may run it; only once nothing runs here, or two engines would drive one attempt.
  func relinquish() {
    precondition(runner.runningAttempts.isEmpty, "an engine gives its vault up only once none of its attempts runs")
    claim.release()
  }

  /// The job's key; a request already made answers its job as stored, and a cancelled or failed job is requested again as its next run
  /// (apps/novel-forge-server/src/modules/jobs/job.service.ts:133-135, 165-175 resets a terminal job).
  @concurrent
  public func request(_ request: NovelJobRequest) async throws(JobEngineError) -> JobKey {
    guard request.chapter >= 1 else { throw .chapterOutOfRange(request.chapter) }
    do {
      _ = try request.key(run: 1)
    } catch {
      throw .key(error)
    }
    let (replica, now) = (store.replica, clock.now())
    return try await engineWrite { transaction in try request.enqueue(replica: replica, now: now, in: &transaction) }
  }

  /// Requests the job's cancel; an attempt running here stops at once and ends cancelled, its in-flight call aborted.
  @concurrent
  public func cancel(job: EntityRef) async throws(JobEngineError) -> JobCancelOutcome {
    do {
      return try await runner.cancel(job: job)
    } catch .record(.jobNotFound) {
      throw .jobNotFound(job)
    } catch {
      throw .run(error)
    }
  }

  /// Runs the job here as the device that requested it does (orchestrator decision 9): it stands down for an attempt that started earlier and holds a live
  /// lease.
  @concurrent
  public func run(job: EntityRef) async throws(JobEngineError) -> JobRunHandle {
    try await start(job, byHand: false)
  }

  /// "Run here", offered only while no other device's attempt holds a live lease; once started by hand it never stands down for one.
  @concurrent
  public func runHere(job: EntityRef) async throws(JobEngineError) -> JobRunHandle {
    try await start(job, byHand: true)
  }

  /// At launch: resumes every attempt this device was running from its last checkpoint, settles those it had stopped, and clears the packs of settled ones.
  @concurrent
  public func resumeInterruptedAttempts() async throws(JobEngineError) -> [JobRunHandle] {
    let resumed: [AttemptHandle]
    do {
      resumed = try await runner.resumeInterrupted { [self] job in attemptPipeline(for: job) }
    } catch {
      throw .run(error)
    }
    await forgetSettledPacks()
    return resumed.map(track)
  }

  /// The job's status and step as this device sees it, again after every commit and whenever a lease's liveness changes; step names only, never a call's
  /// text.
  public func observe(job: EntityRef) -> AsyncThrowingStream<JobProgress, any Error> {
    let replica = store.replica
    return observeLeased { [self] transaction, now in
      let snapshot = try JobSnapshot.load(job, in: transaction)
      return JobProgress(snapshot, at: now, replica: replica, runningHere: Set(runner.runningAttempts))
    }
  }

  /// The novel's jobs in flight, re-read at `JobActivity.changesAt` as well as after every commit.
  public func observeActivity(novel: UUID) -> AsyncThrowingStream<JobActivity, any Error> {
    observeLeased { transaction, now in try JobActivity.load(JobActivityQuery(novel: novel, now: now), in: transaction) }
  }

  private func start(_ job: EntityRef, byHand: Bool) async throws(JobEngineError) -> JobRunHandle {
    let task = starting.withLock { tasks in
      if let running = tasks[job] { return running }
      let task = Task { [self] in
        let result: Result<JobRunHandle, JobEngineError>
        do throws(JobEngineError) {
          result = .success(try await launch(job, byHand: byHand))
        } catch {
          result = .failure(error)
        }
        _ = starting.withLock { $0.removeValue(forKey: job) }
        return result
      }
      tasks[job] = task
      return task
    }
    return try await task.value.get()
  }

  private func launch(_ job: EntityRef, byHand: Bool) async throws(JobEngineError) -> JobRunHandle {
    if let running = running({ $0.job == job }) { return running }
    let snapshot = try await engineRead { transaction in try JobSnapshot.load(job, in: transaction) }
    guard let snapshot else { throw .jobNotFound(job) }
    guard let target = NovelJobTarget(snapshot.job.request.key) else { throw .notANovelJob(job) }
    let pipeline = try ready(target.kind)
    let now = clock.now()
    if byHand, let live = snapshot.attempts.first(where: { $0.isLive(at: now) && $0.start.replica != store.replica }) {
      throw .runningElsewhere(live.id, live.start.replica)
    }
    let (pins, mode) = try await pin(target, payload: snapshot.job.request.payload, pipeline: pipeline.version)
    if let missing = try await missingConsent(mode) { throw .consentRequired(missing) }
    if faults.crashes(.pinned) { throw .run(.interrupted) }
    let started: AttemptHandle
    do {
      started = try await runner.start(job: job, pipeline: adapt(pipeline), input: snapshot.job.request.payload, pinned: pins.json, byHand: byHand)
    } catch .alreadyRunningHere(let held) {
      return try await resumeHeld(held, snapshot: snapshot, pipeline: pipeline, pins: pins, byHand: byHand)
    } catch .anotherAttemptLive(let leader) {
      throw try await runningElsewhere(leader, job: job)
    } catch {
      throw .run(error)
    }
    return track(started)
  }

  /// `start` refused because this device holds a run of the job (G12): that run is resumed, or, once it settled, the job is started afresh once.
  private func resumeHeld(
    _ held: AttemptID, snapshot: JobSnapshot, pipeline: NovelPipeline, pins: JobPins, byHand: Bool
  ) async throws(JobEngineError) -> JobRunHandle {
    if let running = running({ $0.attempt == held }) { return running }
    let job = snapshot.job.ref
    do {
      if let resumed = try await runner.resume(held, pipeline: { [self] job in attemptPipeline(for: job) }) { return track(resumed) }
      await forgetSettledPacks()
      return track(try await runner.start(job: job, pipeline: adapt(pipeline), input: snapshot.job.request.payload, pinned: pins.json, byHand: byHand))
    } catch .anotherAttemptLive(let leader) {
      throw try await runningElsewhere(leader, job: job)
    } catch {
      throw .run(error)
    }
  }

  /// The leader as the runner's own read found it, which may have arrived after this start's first read.
  private func runningElsewhere(_ leader: AttemptID, job: EntityRef) async throws(JobEngineError) -> JobEngineError {
    let snapshot = try await engineRead { transaction in try JobSnapshot.load(job, in: transaction) }
    let replica = snapshot?.attempts.first { $0.id == leader }?.start.replica ?? store.replica
    return .runningElsewhere(leader, replica)
  }

  /// Every pipeline sends the novel's text, so an attempt started without consent would only fail at its first call and use the run up.
  private func missingConsent(_ mode: ModelContentMode) async throws(JobEngineError) -> AIConsentRequest? {
    let router = await services.router { _ in nil }
    do {
      return try await router.missingConsent(services.consent, contentMode: mode)
    } catch .ledger(let error) {
      throw .store(error)
    } catch {
      throw .store(.aborted(error))
    }
  }

  /// The pins, read without writing, and the content mode the job's calls take, for its consent.
  private func pin(_ target: NovelJobTarget, payload: JSONValue, pipeline version: Int) async throws(JobEngineError) -> (JobPins, ModelContentMode) {
    let unrestrictedAvailable = services.unrestrictedAvailable
    return try await engineWrite { transaction in
      (try JobPins.pin(target, pipeline: version, in: transaction), Self.contentMode(target, payload: payload, unrestrictedAvailable: unrestrictedAvailable, in: transaction))
    }
  }

  /// As the chapter's calls route it (ChapterCallRouter): an isolated draft, a plan that names unrestricted or a payload that raises the call is unrestricted
  /// where this build writes it; anything this version cannot read checks the standard host, and the call itself refuses later.
  static func contentMode(
    _ target: NovelJobTarget, payload: JSONValue, unrestrictedAvailable: Bool, in transaction: borrowing WriteTransaction
  ) -> ModelContentMode {
    guard unrestrictedAvailable else { return .standard }
    let plan = (try? transaction.planHead(novel: target.novel, chapter: target.chapter))?.record.content
    var isolated = false
    if case .live(let head)? = try? transaction.draft(novel: target.novel, chapter: target.chapter) { isolated = head.content.isolated }
    let source = ChapterCallSource(
      novel: target.novel, chapter: target.chapter, role: .draft, plan: plan, isolated: isolated, raised: payload["unrestricted"]?.boolValue == true)
    return (try? ChapterCallRouter.route(source, unrestrictedAvailable: true))?.contentMode ?? .standard
  }

  private func ready(_ kind: NovelJobKind) throws(JobEngineError) -> NovelPipeline {
    switch catalog(kind) {
    case .ready(let pipeline): return pipeline
    case .notYetAvailable(let kind): throw .pipelineNotYetAvailable(kind)
    }
  }

  /// Nil for a job no pipeline of this version runs, which the runner leaves for a launch that has one.
  private func attemptPipeline(for job: JobRecord) -> AttemptPipeline? {
    guard let target = NovelJobTarget(job.request.key), case .ready(let pipeline) = catalog(target.kind) else { return nil }
    return adapt(pipeline)
  }

  private func adapt(_ pipeline: NovelPipeline) -> AttemptPipeline {
    AttemptPipeline(first: pipeline.first, steps: pipeline.steps.mapValues { EngineStep(step: $0, version: pipeline.version, services: services) })
  }

  /// A handle whose run ended stays tracked until its result is read, so only one the runner still runs is answered.
  private func running(_ matches: (JobRunHandle) -> Bool) -> JobRunHandle? {
    let running = Set(runner.runningAttempts)
    return handles.withLock { $0.values.first { running.contains($0.attempt) && matches($0) } }
  }

  private func track(_ started: AttemptHandle) -> JobRunHandle {
    let handle = JobRunHandle(job: started.job, attempt: started.attempt, handle: started) { [self] in
      _ = handles.withLock { $0.removeValue(forKey: started.attempt) }
      await forgetSettledPacks()
    }
    handles.withLock { $0[started.attempt] = handle }
    Task.detached { _ = await handle.result }
    return handle
  }

  private func forgetSettledPacks() async {
    let replica = store.replica
    do throws(StoreError) {
      _ = try await store.write { transaction in try WriterPackPins.forgetSettled(keeping: replica, in: transaction.database) }
    } catch {
      Self.logger.notice("Could not clear the writer packs of settled attempts code=\(error.code, privacy: .public)")
    }
  }

  private func observeLeased<Value: Sendable & Equatable & LeaseTimed>(
    _ read: @escaping @Sendable (ReadTransaction, LeaseInstant) throws -> Value
  ) -> AsyncThrowingStream<Value, any Error> {
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let (store, clock, timing) = (store, clock, timing)
    let commits = Task {
      do {
        for try await _ in store.observeReads({ transaction in try read(transaction, clock.now()) }) { wake.yield() }
      } catch {
        continuation.finish(throwing: error)
      }
      wake.finish()
    }
    let reader = Task {
      var last: Value?
      var timer: Task<Void, Never>?
      for await _ in wakes {
        let value: Value
        do {
          value = try await store.read { transaction in try read(transaction, clock.now()) }
        } catch {
          continuation.finish(throwing: error)
          break
        }
        if value != last { continuation.yield(value) }
        last = value
        timer?.cancel()
        timer = value.changesAt.map { changesAt in
          let delay = Duration.milliseconds(max(0, Int64((changesAt.timeIntervalSince(clock.now().date) * 1000).rounded(.up))))
          return Task {
            guard (try? await timing.sleep(delay)) != nil else { return }
            wake.yield()
          }
        }
      }
      timer?.cancel()
      continuation.finish()
    }
    continuation.onTermination = { @Sendable _ in
      commits.cancel()
      reader.cancel()
      wake.finish()
    }
    return stream
  }

  private func engineRead<T: Sendable>(_ body: @Sendable (ReadTransaction) throws -> T) async throws(JobEngineError) -> T {
    do {
      return try await store.read(body)
    } catch {
      throw Self.converting(error)
    }
  }

  private func engineWrite<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(JobEngineError) -> T {
    do {
      return try await store.write(body)
    } catch {
      throw Self.converting(error)
    }
  }

  private static func converting(_ error: StoreError) -> JobEngineError {
    guard case .aborted(let inner) = error else { return .store(error) }
    switch inner {
    case let inner as JobEngineError: return inner
    case let inner as JobRecordError: return .record(inner)
    case let inner as JobKeyError: return .key(inner)
    case let inner as StoreError: return converting(inner)
    default: return .store(error)
    }
  }
}

extension NovelJobRequest {
  func key(run: Int) throws(JobKeyError) -> JobKey {
    try JobKey(scope: NovelJobAddress.scope(of: novel), kind: kind.rawValue, target: NovelJobAddress.target(chapter: chapter), fingerprint: fingerprint, run: run)
  }

  /// Writes the request into the caller's transaction, so a card action's settling and its job commit together.
  func enqueue(replica: ReplicaID, now: LeaseInstant, in transaction: inout WriteTransaction) throws -> JobKey {
    var run = 1
    while try transaction.state(of: try key(run: run).ref) != nil { run += 1 }
    let highest = run > 1 ? try JobSnapshot.load(try key(run: run - 1).ref, in: transaction) : nil
    let stale =
      highest.map { snapshot in
        let status = JobStatus(snapshot, at: now)
        guard case .succeeded = status else { return rerun || status == .cancelled || status.phase == .failed }
        return rerun || rerunOnceSucceeded
      } ?? (run > 1)
    let requested = try key(run: run == 1 ? 1 : (stale ? run : run - 1))
    _ = try JobRecords.request(JobRequest(key: requested, payload: payload, origin: origin, replica: replica), in: &transaction)
    return requested
  }
}

/// What a lease-timed read says about when it next changes with no write.
protocol LeaseTimed {
  var changesAt: Date? { get }
}

extension JobActivity: LeaseTimed {}

/// Claims a vault for one engine: in this process by the store and by the replica it syncs as, so a second store opened on the same database is refused too,
/// and across processes by the vault's jobs lock, so a second copy of the app on the vault runs nothing. A release frees only its own claim, so a released
/// engine that lingers never frees the claim of the engine after it.
final class JobEngineClaim: Sendable {
  private static let claimed = Mutex<(stores: [ObjectIdentifier: UUID], replicas: [ReplicaID: UUID])>(([:], [:]))

  private let store: ObjectIdentifier
  private let replica: ReplicaID
  private let token: UUID
  private let lock: VaultProcessLock

  init(_ store: VaultStore) throws(JobEngineError) {
    let (identity, replica, token) = (ObjectIdentifier(store), store.replica, UUID())
    let claimed = Self.claimed.withLock { claimed in
      guard claimed.stores[identity] == nil, claimed.replicas[replica] == nil else { return false }
      claimed.stores[identity] = token
      claimed.replicas[replica] = token
      return true
    }
    guard claimed else { throw .engineExists }
    self.store = identity
    self.replica = replica
    self.token = token
    let lock: VaultProcessLock?
    do {
      lock = try store.acquireProcessLock(.jobs)
    } catch {
      Self.unclaim(identity, replica, token)
      throw .store(error)
    }
    guard let lock else {
      Self.unclaim(identity, replica, token)
      throw .heldByAnotherProcess
    }
    self.lock = lock
  }

  func release() {
    lock.release()
    Self.unclaim(store, replica, token)
  }

  private static func unclaim(_ store: ObjectIdentifier, _ replica: ReplicaID, _ token: UUID) {
    claimed.withLock { claimed in
      if claimed.stores[store] == token { claimed.stores[store] = nil }
      if claimed.replicas[replica] == token { claimed.replicas[replica] = nil }
    }
  }
}
