import Foundation
import NovelForgeCore
import OSLog
import Observation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore
import SwiftUI

/// One job runtime per open vault, shared by every window, as `ChatRuntimes` keeps one turn engine: a second engine on the vault would be refused.
@MainActor
@Observable
final class JobRuntimes {
  private var current: (store: ObjectIdentifier, runtime: JobRuntime)?
  @ObservationIgnored private let host: any JobRunHost

  init(host: any JobRunHost = ForegroundRunHost()) {
    self.host = host
  }

  /// The vault's runtime once the app has made it; a view reads this and never makes one.
  func existing(for store: VaultStore) -> JobRuntime? {
    guard let current, current.store == ObjectIdentifier(store) else { return nil }
    return current.runtime
  }

  func runtime(for store: VaultStore, services: AIServices, trustedClock: TrustedClock) -> JobRuntime {
    if let existing = existing(for: store) { return existing }
    current?.runtime.shutDown()
    let created = JobRuntime.live(store: store, services: services, trustedClock: trustedClock, host: host)
    current = (ObjectIdentifier(store), created)
    return created
  }

  func launch(_ store: VaultStore?, services: AIServices, trustedClock: TrustedClock) async {
    guard let store else { return }
    await runtime(for: store, services: services, trustedClock: trustedClock).launch()
  }

  func phaseChanged(_ phase: ScenePhase) async {
    guard let runtime = current?.runtime else { return }
    switch phase {
    case .active: await runtime.sceneBecameActive()
    case .background: runtime.sceneEnteredBackground()
    default: return
    }
  }
}

/// The engine calls the runtime makes, each the engine's own unless a test replaces it.
nonisolated struct JobEngineCalls: Sendable {
  typealias Start = @Sendable (JobEngine, EntityRef) async throws(JobEngineError) -> JobRunHandle

  var run: Start
  var runHere: Start
  var resumeHere: Start
  var resumeInterrupted: @Sendable (JobEngine) async throws(JobEngineError) -> [JobRunHandle]
  var settleStopped: @Sendable (JobEngine) async throws(JobEngineError) -> [AttemptID]
  var interruptedRuns: @Sendable (JobEngine) async throws(JobEngineError) -> [InterruptedJobRun]
  /// Releases the lease, so another device may take the job over at once.
  var interrupt: @Sendable (JobEngine, EntityRef) async throws(JobEngineError) -> JobInterruption
  var observeRun: @Sendable (JobEngine, AttemptID) -> AsyncStream<JobRunProgress>

  init(
    run: @escaping Start = { engine, job throws(JobEngineError) in try await engine.run(job: job) },
    runHere: @escaping Start = { engine, job throws(JobEngineError) in try await engine.runHere(job: job) },
    resumeHere: @escaping Start = { engine, job throws(JobEngineError) in try await engine.resumeHere(job: job) },
    resumeInterrupted: @escaping @Sendable (JobEngine) async throws(JobEngineError) -> [JobRunHandle] = { engine throws(JobEngineError) in
      try await engine.resumeInterruptedAttempts()
    },
    settleStopped: @escaping @Sendable (JobEngine) async throws(JobEngineError) -> [AttemptID] = { engine throws(JobEngineError) in
      try await engine.settleStoppedAttempts()
    },
    interruptedRuns: @escaping @Sendable (JobEngine) async throws(JobEngineError) -> [InterruptedJobRun] = { engine throws(JobEngineError) in
      try await engine.interruptedRuns()
    },
    interrupt: @escaping @Sendable (JobEngine, EntityRef) async throws(JobEngineError) -> JobInterruption = { engine, job throws(JobEngineError) in
      try await engine.interrupt(job: job, releasingLease: true)
    },
    observeRun: @escaping @Sendable (JobEngine, AttemptID) -> AsyncStream<JobRunProgress> = { engine, attempt in engine.observeRun(attempt: attempt) }
  ) {
    self.run = run
    self.runHere = runHere
    self.resumeHere = resumeHere
    self.resumeInterrupted = resumeInterrupted
    self.settleStopped = settleStopped
    self.interruptedRuns = interruptedRuns
    self.interrupt = interrupt
    self.observeRun = observeRun
  }
}

/// Runs this vault's jobs on this device through one `JobEngine`, placed by `JobPlacementPolicy`. At launch a Mac resumes the attempts it was running; an
/// iPhone or iPad resumes nothing, settles its stop marks and lists the runs it can resume, which its lines offer as Resume. Then it starts, one at a time,
/// the jobs the policy gives this device: card actions, approvals' finalize reviews and finals' canon refreshes request their jobs in their own writes, so
/// they arrive here, and the worker Mac also takes the vault's `WorkerBacklog`, resuming a run of its own there rather than starting another attempt. A job
/// whose start is refused is tried again only when the queue changes, and the queue is read again when a lease lapses. While the novel's text may not be
/// sent it starts nothing and waits for consent. While another copy of the app holds the vault's jobs lock it runs nothing and tries to take the vault over
/// now and then.
@MainActor
@Observable
final class JobRuntime {
  enum Mode: Equatable {
    case starting
    case running
    /// Another copy of the app on this vault runs its jobs.
    case elsewhere
    case unavailable(PresentedError)
  }

  typealias EngineFactory = @Sendable () throws(JobEngineError) -> JobEngine

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "jobs")

  let store: VaultStore
  let clock: LeaseClock
  let platform: JobPlatform
  private(set) var mode = Mode.starting
  /// The jobs an action of this device's is starting or cancelling.
  private(set) var pending: Set<EntityRef> = []
  /// The consent every start waits for; set when the engine refused one for it.
  private(set) var consentNeeded: AIConsentRequest?
  /// This device's stopped runs that Resume continues, by job, as the engine last listed them.
  private(set) var resumable: [EntityRef: InterruptedJobRun] = [:]
  @ObservationIgnored private(set) var engine: JobEngine?
  @ObservationIgnored private let makeEngine: EngineFactory
  @ObservationIgnored private let calls: JobEngineCalls
  @ObservationIgnored private let host: any JobRunHost
  @ObservationIgnored private let power: JobPowerAssertion
  @ObservationIgnored private let settler: CostSettler?
  @ObservationIgnored private let takeOverDelay: Duration
  @ObservationIgnored private var launching: Task<Void, Never>?
  @ObservationIgnored private var takingOver: Task<Void, Never>?
  @ObservationIgnored private var draining: Task<Void, Never>?
  @ObservationIgnored private var repolling: Task<Void, Never>?
  @ObservationIgnored private var following: Set<AttemptID> = []
  /// The jobs queued when the engine started: the drain starts them with no one asking, until consent given here starts the queue again.
  @ObservationIgnored private var queuedAtLaunch: Set<EntityRef>? = []
  @ObservationIgnored private var listings = 0

  init(
    store: VaultStore, clock: LeaseClock, platform: JobPlatform = .current, power: JobPowerAssertion = JobPowerAssertion(), takeOverDelay: Duration = .seconds(30),
    settler: CostSettler? = nil, host: any JobRunHost = ForegroundRunHost(), calls: JobEngineCalls = JobEngineCalls(), makeEngine: @escaping EngineFactory
  ) {
    self.store = store
    self.clock = clock
    self.platform = platform
    self.power = power
    self.takeOverDelay = takeOverDelay
    self.settler = settler
    self.host = host
    self.calls = calls
    self.makeEngine = makeEngine
  }

  /// `trustedClock` is the vault's, which sync feeds from the storage's time, so leases are stamped and read against it.
  static func live(store: VaultStore, services: AIServices, trustedClock: TrustedClock, host: any JobRunHost = ForegroundRunHost()) -> JobRuntime {
    let clock = LeaseClock(trusted: trustedClock)
    let (consent, embedders) = (ConsentDisclosure.novelText.requirement, services.embedders)
    return JobRuntime(store: store, clock: clock, settler: services.settler(for: store), host: host) { () throws(JobEngineError) -> JobEngine in
      try JobEngine(
        store: store, router: { requestGuard in await services.router(store: store, requestGuard: requestGuard) }, consent: consent, clock: clock, embedders: embedders)
    }
  }

  var runsJobs: Bool { mode == .running }

  var here: JobsHere {
    switch mode {
    case .running: .running
    case .starting: .starting
    case .elsewhere: .elsewhere
    case .unavailable: .unavailable
    }
  }

  var standing: JobsStanding {
    JobsStanding(here: here, platform: platform, consentNeeded: consentNeeded != nil, resumable: Set(resumable.keys))
  }

  var isHoldingPower: Bool { power.isHeld }

  /// A screen asking for a job of `kind` starts it here when this is true, and only requests it otherwise.
  func startsWhenAsked(_ kind: NovelJobKind) -> Bool {
    JobPlacementPolicy.startsWhenAsked(kind, on: platform)
  }

  /// Once per vault open; another call waits for the first.
  func launch() async {
    if let launching { return await launching.value }
    settler?.settleLeftovers()
    let task = Task { await claim() }
    launching = task
    await task.value
  }

  func shutDown() {
    for task in [launching, takingOver, draining, repolling] { task?.cancel() }
    (launching, takingOver, draining, repolling, engine) = (nil, nil, nil, nil, nil)
    following = []
    resumable = [:]
    settler?.shutDown()
    power.release()
  }

  func sceneEnteredBackground() {
    host.sceneEnteredBackground()
  }

  /// Runs the system stopped while the app was away are listed again, so their lines offer Resume.
  func sceneBecameActive() async {
    host.sceneBecameActive()
    guard let engine else { return }
    await listResumable(engine)
  }

  /// "Run here": refused while another device's attempt holds a live lease.
  func runHere(_ job: EntityRef) async -> PresentedError? {
    await act(on: job) { [calls] engine throws(JobEngineError) in try await calls.runHere(engine, job) }
  }

  /// Continues this device's stopped run of the job from its checkpoint; refused while another device's attempt it would not outrank is live.
  func resume(_ job: EntityRef) async -> PresentedError? {
    await act(on: job) { [calls] engine throws(JobEngineError) in try await calls.resumeHere(engine, job) }
  }

  /// Runs a failed job again as a new attempt of the same run.
  func tryAgain(_ job: EntityRef) async -> PresentedError? {
    await act(on: job) { [calls] engine throws(JobEngineError) in try await calls.run(engine, job) }
  }

  func cancel(_ job: EntityRef) async -> PresentedError? {
    guard let engine else { return JobsErrors.notRunningHere }
    pending.insert(job)
    defer { pending.remove(job) }
    do throws(JobEngineError) {
      _ = try await engine.cancel(job: job)
      return nil
    } catch {
      return JobsErrors.presented(error)
    }
  }

  /// The pair that runs an approval's read of its Story Bible updates, and runs a failed read again: the head's job under the current plan, then `run`.
  func retryRead(novel: UUID, chapter: Int, shown: EntityRef) async -> PresentedError? {
    guard runsJobs else { return JobsErrors.notRunningHere }
    let found: EntityRef?
    do throws(DomainError) {
      found = try await store.finalizeReviewJob(novel: novel, chapter: chapter)
    } catch {
      return JobsErrors.presented(error)
    }
    guard let job = found else { return JobsErrors.readNeedsApproval }
    return await act(on: shown) { [calls] engine throws(JobEngineError) in try await calls.run(engine, job) }
  }

  /// After the consent sheet allowed sending: the queue is read and started again, whichever host the consent was for.
  func consentAllowed() {
    guard consentNeeded != nil else { return }
    consentNeeded = nil
    queuedAtLaunch = []
    guard let engine else { return }
    drain(engine)
  }

  /// Holds the Mac awake until the run ends and hands the run to the host; for runs started outside the runtime too, such as a generation asked for from its
  /// screen.
  func follow(_ handle: JobRunHandle, origin: JobRunOrigin) {
    guard following.insert(handle.attempt).inserted else { return }
    resumable[handle.job] = nil
    power.begin()
    let finished = Task { await handle.result }
    if let engine { hand(handle, origin: origin, finished: finished, engine: engine) }
    Task { [weak self] in
      _ = await finished.value
      self?.ended(handle.attempt)
    }
  }

  /// True while the job's run here goes on only as long as the app stays open.
  func needsAppOpen(_ job: EntityRef) -> Bool {
    host.needsAppOpen(for: job)
  }

  /// The run's progress is observed at once so none is missed while the job's record is read for its kind and chapter.
  private func hand(_ handle: JobRunHandle, origin: JobRunOrigin, finished: Task<AttemptResult, Never>, engine: JobEngine) {
    let (store, job, progress) = (store, handle.job, calls.observeRun(engine, handle.attempt))
    Task { [weak self] in
      let target = try? await store.read { transaction in try Self.target(of: job, in: transaction) }
      guard let self else { return }
      self.host.host(self.hosted(handle, target: target, origin: origin, progress: progress, finished: finished, engine: engine))
    }
  }

  nonisolated private static func target(of job: EntityRef, in transaction: ReadTransaction) throws(JobRecordError) -> NovelJobTarget? {
    guard let key = try JobRecords.read(job, in: transaction).record?.request.key, let kind = NovelJobKind(rawValue: key.kind),
      let novel = NovelJobAddress.novel(ofScope: key.scope), let chapter = NovelJobAddress.chapter(ofTarget: key.target)
    else { return nil }
    return NovelJobTarget(novel: novel, chapter: chapter, kind: kind)
  }

  private func hosted(
    _ handle: JobRunHandle, target: NovelJobTarget?, origin: JobRunOrigin, progress: AsyncStream<JobRunProgress>, finished: Task<AttemptResult, Never>,
    engine: JobEngine
  ) -> HostedJobRun {
    let (calls, job) = (calls, handle.job)
    return HostedJobRun(
      job: job, attempt: handle.attempt, target: target, origin: origin, progress: progress,
      interrupt: { [weak self] () async throws(JobEngineError) -> JobInterruption in
        let interruption = try await calls.interrupt(engine, job)
        await self?.listResumable(engine)
        return interruption
      },
      finished: { await finished.value })
  }

  private func ended(_ attempt: AttemptID) {
    guard following.remove(attempt) != nil else { return }
    power.end()
    settler?.settle()
    guard let engine else { return }
    Task { await listResumable(engine) }
  }

  private func act(on job: EntityRef, _ start: (JobEngine) async throws(JobEngineError) -> JobRunHandle) async -> PresentedError? {
    guard let engine else { return JobsErrors.notRunningHere }
    pending.insert(job)
    defer { pending.remove(job) }
    do throws(JobEngineError) {
      follow(try await start(engine), origin: .person)
      await listResumable(engine)
      return nil
    } catch .consentRequired(let request) {
      wait(for: request, engine: engine)
      return nil
    } catch {
      await listResumable(engine)
      return await presented(error)
    }
  }

  /// A refusal for another device's live run names that device as the replica directory does.
  private func presented(_ error: JobEngineError) async -> PresentedError {
    guard case .runningElsewhere(_, let replica) = error else { return JobsErrors.presented(error) }
    return JobsErrors.presented(error, holder: await SyncRuntimes.deviceNames(for: [replica], in: store)[replica])
  }

  private func claim() async {
    let engine: JobEngine
    do throws(JobEngineError) {
      engine = try makeEngine()
    } catch .heldByAnotherProcess {
      mode = .elsewhere
      scheduleTakeOver()
      return
    } catch {
      Self.logger.error("The job engine could not start code=\(error.code, privacy: .public)")
      mode = .unavailable(JobsErrors.presented(error))
      return
    }
    self.engine = engine
    mode = .running
    switch platform {
    case .mac: await resumeInterrupted(engine)
    case .phone: await settle(engine)
    }
    await listResumable(engine)
    queuedAtLaunch = await readQueued()
    drain(engine)
  }

  private func scheduleTakeOver() {
    let delay = takeOverDelay
    takingOver = Task { [weak self] in
      guard (try? await Task.sleep(for: delay)) != nil else { return }
      await self?.claim()
    }
  }

  private func resumeInterrupted(_ engine: JobEngine) async {
    do throws(JobEngineError) {
      let resumed = try await calls.resumeInterrupted(engine)
      Self.logger.info("Resumed interrupted job attempts count=\(resumed.count, privacy: .public)")
      for handle in resumed { follow(handle, origin: .automatic) }
    } catch {
      Self.logger.error("Interrupted job attempts could not be resumed code=\(error.code, privacy: .public)")
    }
  }

  private func settle(_ engine: JobEngine) async {
    do throws(JobEngineError) {
      let settled = try await calls.settleStopped(engine)
      Self.logger.info("Settled stopped job attempts count=\(settled.count, privacy: .public)")
    } catch {
      Self.logger.error("Stopped job attempts could not be settled code=\(error.code, privacy: .public)")
    }
  }

  /// The latest listing wins, so one that finishes after a later one leaves the later one's runs.
  private func listResumable(_ engine: JobEngine) async {
    listings += 1
    let listing = listings
    do throws(JobEngineError) {
      let runs = try await calls.interruptedRuns(engine)
      guard listing == listings, self.engine === engine else { return }
      resumable = Dictionary(runs.map { ($0.job, $0) }) { first, _ in first }
    } catch {
      Self.logger.error("This device's stopped job runs could not be listed code=\(error.code, privacy: .public)")
    }
  }

  private func wait(for request: AIConsentRequest, engine: JobEngine) {
    consentNeeded = request
    drain(engine)
  }

  /// Observes the queue together with the consent it waits for, so a grant made anywhere, a chat's consent sheet included, starts it again; the store
  /// publishes a read only when it changed, which makes a refused start one try per distinct queue. A drain started again waits for the one before it,
  /// which ends once the job it runs has ended, so jobs still start one at a time. A lease that lapses changes the queue with no write, so the queue is
  /// observed again at its `changesAt`.
  private func drain(_ engine: JobEngine) {
    let previous = draining
    previous?.cancel()
    repolling?.cancel()
    let (store, read) = (store, queueRead())
    draining = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, self != nil else { return }
      let waiting = self?.consentNeeded
      do {
        for try await queue in store.observeReads({ transaction in try read(waiting, transaction) }) {
          guard let self, !Task.isCancelled else { return }
          if queue.consented == true { self.consentNeeded = nil }
          let request = await self.start(queue.jobs, on: engine)
          guard !Task.isCancelled, self.engine === engine else { return }
          if let request {
            self.wait(for: request, engine: engine)
            return
          }
          self.repoll(at: queue.changesAt, engine: engine)
        }
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error("Stopped following the jobs this device runs")
      }
    }
  }

  private func queueRead() -> @Sendable (AIConsentRequest?, ReadTransaction) throws -> JobQueue {
    let (replica, platform, clock) = (store.replica, platform, clock)
    return { waiting, transaction in try JobQueue(replica: replica, platform: platform, now: clock.now(), waiting: waiting, in: transaction) }
  }

  private func repoll(at changesAt: Date?, engine: JobEngine) {
    repolling?.cancel()
    repolling = nil
    guard let changesAt else { return }
    let delay = max(0, changesAt.timeIntervalSince(clock.now().date))
    repolling = Task { [weak self] in
      guard (try? await Task.sleep(for: .seconds(delay) + .milliseconds(1))) != nil, let self, self.engine === engine else { return }
      self.drain(engine)
    }
  }

  /// One at a time, each job once per distinct queue; answers the consent a refused start waits for, after which nothing starts until it is given. Each job
  /// is checked against the queue as it reads now, since the worker may have changed while the job before it ran.
  private func start(_ jobs: [EntityRef], on engine: JobEngine) async -> AIConsentRequest? {
    for job in jobs {
      guard consentNeeded == nil, !Task.isCancelled else { return nil }
      guard await isQueued(job) else { continue }
      do throws(JobEngineError) {
        let handle = try await begin(job, on: engine)
        follow(handle, origin: origin(of: job))
        _ = await handle.result
      } catch .consentRequired(let request) {
        return request
      } catch {
        Self.logger.notice("A job this device runs did not start code=\(error.code, privacy: .public)")
      }
    }
    return nil
  }

  private func isQueued(_ job: EntityRef) async -> Bool {
    await queued().contains(job)
  }

  private func queued() async -> Set<EntityRef> {
    await readQueued() ?? []
  }

  private func readQueued() async -> Set<EntityRef>? {
    let (read, waiting) = (queueRead(), consentNeeded)
    return (try? await store.read { transaction in try read(waiting, transaction) }).map { Set($0.jobs) }
  }

  /// A launch whose queue could not be read treats every job as automatic, so no request reaches the system without a person's action.
  private func origin(of job: EntityRef) -> JobRunOrigin {
    guard let queuedAtLaunch, !queuedAtLaunch.contains(job) else { return .automatic }
    return .person
  }

  /// A job whose last attempt is this device's stopped run continues that run rather than starting another attempt.
  private func begin(_ job: EntityRef, on engine: JobEngine) async throws(JobEngineError) -> JobRunHandle {
    guard resumable[job] != nil else { return try await calls.run(engine, job) }
    do throws(JobEngineError) {
      return try await calls.resumeHere(engine, job)
    } catch .nothingToResume {
      resumable[job] = nil
      return try await calls.run(engine, job)
    }
  }
}
