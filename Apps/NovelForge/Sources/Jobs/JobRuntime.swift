import Foundation
import NovelForgeCore
import OSLog
import Observation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// One job runtime per open vault, shared by every window, as `ChatRuntimes` keeps one turn engine: a second engine on the vault would be refused.
@MainActor
@Observable
final class JobRuntimes {
  private var current: (store: ObjectIdentifier, runtime: JobRuntime)?

  /// The vault's runtime once the app has made it; a view reads this and never makes one.
  func existing(for store: VaultStore) -> JobRuntime? {
    guard let current, current.store == ObjectIdentifier(store) else { return nil }
    return current.runtime
  }

  func runtime(for store: VaultStore, services: AIServices) -> JobRuntime {
    if let existing = existing(for: store) { return existing }
    current?.runtime.shutDown()
    let created = JobRuntime.live(store: store, services: services)
    current = (ObjectIdentifier(store), created)
    return created
  }

  func launch(_ store: VaultStore?, services: AIServices) async {
    guard let store else { return }
    await runtime(for: store, services: services).launch()
  }
}

/// The jobs this device asked for and has not started, and whether the consent the runtime waits for has been given since (nil while it waits for none).
nonisolated struct JobQueue: Equatable, Sendable {
  let jobs: [EntityRef]
  let consented: Bool?

  init(replica: ReplicaID, waiting: AIConsentRequest?, in transaction: ReadTransaction) throws {
    jobs = try JobBacklog.load(replica, in: transaction).jobs.value ?? []
    consented = try waiting.map { try AIConsent.isGranted(provider: $0.host, dataClass: $0.dataClass, currentSummary: $0.disclosure, in: transaction) }
  }
}

/// Runs this vault's jobs on this device through one `JobEngine`. At launch it resumes the attempts this device was running, then starts, one at a time,
/// every job this device asked for that no attempt has started: card actions, approvals' finalize reviews and finals' canon refreshes request their jobs in
/// their own writes, so they arrive here. A job whose start is refused is tried again only when the queue changes. While the novel's text may not be sent it
/// starts nothing and waits for consent. While another copy of the app holds the vault's jobs lock it runs nothing and tries to take the vault over now and
/// then.
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
  typealias Starter = @Sendable (JobEngine, EntityRef) async throws(JobEngineError) -> JobRunHandle

  nonisolated private static let logger = Logger(subsystem: "com.shadow.apps.novelforge", category: "jobs")

  let store: VaultStore
  let clock: LeaseClock
  private(set) var mode = Mode.starting
  /// The jobs an action of this device's is starting or cancelling.
  private(set) var pending: Set<EntityRef> = []
  /// The consent every start waits for; set when the engine refused one for it.
  private(set) var consentNeeded: AIConsentRequest?
  @ObservationIgnored private(set) var engine: JobEngine?
  @ObservationIgnored private let makeEngine: EngineFactory
  @ObservationIgnored private let starter: Starter
  @ObservationIgnored private let power: JobPowerAssertion
  @ObservationIgnored private let settler: CostSettler?
  @ObservationIgnored private let takeOverDelay: Duration
  @ObservationIgnored private var launching: Task<Void, Never>?
  @ObservationIgnored private var takingOver: Task<Void, Never>?
  @ObservationIgnored private var draining: Task<Void, Never>?
  @ObservationIgnored private var following: Set<AttemptID> = []

  init(
    store: VaultStore, clock: LeaseClock, power: JobPowerAssertion = JobPowerAssertion(), takeOverDelay: Duration = .seconds(30), settler: CostSettler? = nil,
    starter: @escaping Starter = { engine, job throws(JobEngineError) in try await engine.run(job: job) }, makeEngine: @escaping EngineFactory
  ) {
    self.store = store
    self.clock = clock
    self.power = power
    self.takeOverDelay = takeOverDelay
    self.settler = settler
    self.starter = starter
    self.makeEngine = makeEngine
  }

  static func live(store: VaultStore, services: AIServices) -> JobRuntime {
    let clock = LeaseClock(trusted: nil)
    let consent = ConsentDisclosure.novelText.requirement
    return JobRuntime(store: store, clock: clock, settler: services.settler(for: store)) { () throws(JobEngineError) -> JobEngine in
      try JobEngine(store: store, router: { requestGuard in await services.router(store: store, requestGuard: requestGuard) }, consent: consent, clock: clock)
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

  var isHoldingPower: Bool { power.isHeld }

  /// Once per vault open; another call waits for the first.
  func launch() async {
    if let launching { return await launching.value }
    settler?.settleLeftovers()
    let task = Task { await claim() }
    launching = task
    await task.value
  }

  func shutDown() {
    for task in [launching, takingOver, draining] { task?.cancel() }
    (launching, takingOver, draining, engine) = (nil, nil, nil, nil)
    following = []
    settler?.shutDown()
    power.release()
  }

  /// "Run here": refused while another device's attempt holds a live lease.
  func runHere(_ job: EntityRef) async -> PresentedError? {
    await act(on: job) { engine throws(JobEngineError) in try await engine.runHere(job: job) }
  }

  /// Runs a failed job again as a new attempt of the same run.
  func tryAgain(_ job: EntityRef) async -> PresentedError? {
    await act(on: job) { engine throws(JobEngineError) in try await engine.run(job: job) }
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
    return await act(on: shown) { engine throws(JobEngineError) in try await engine.run(job: job) }
  }

  /// After the consent sheet allowed sending: the queue is read and started again, whichever host the consent was for.
  func consentAllowed() {
    guard consentNeeded != nil else { return }
    consentNeeded = nil
    guard let engine else { return }
    drain(engine)
  }

  /// Holds the Mac awake until the run ends; for runs started outside the runtime, such as a generation asked for from its screen.
  func follow(_ handle: JobRunHandle) {
    guard following.insert(handle.attempt).inserted else { return }
    power.begin()
    Task { [weak self] in
      _ = await handle.result
      self?.ended(handle.attempt)
    }
  }

  private func ended(_ attempt: AttemptID) {
    guard following.remove(attempt) != nil else { return }
    power.end()
    settler?.settle()
  }

  private func act(on job: EntityRef, _ start: (JobEngine) async throws(JobEngineError) -> JobRunHandle) async -> PresentedError? {
    guard let engine else { return JobsErrors.notRunningHere }
    pending.insert(job)
    defer { pending.remove(job) }
    do throws(JobEngineError) {
      follow(try await start(engine))
      return nil
    } catch .consentRequired(let request) {
      wait(for: request, engine: engine)
      return nil
    } catch {
      return JobsErrors.presented(error)
    }
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
    await resume(engine)
    drain(engine)
  }

  private func scheduleTakeOver() {
    let delay = takeOverDelay
    takingOver = Task { [weak self] in
      guard (try? await Task.sleep(for: delay)) != nil else { return }
      await self?.claim()
    }
  }

  private func resume(_ engine: JobEngine) async {
    do throws(JobEngineError) {
      let resumed = try await engine.resumeInterruptedAttempts()
      Self.logger.info("Resumed interrupted job attempts count=\(resumed.count, privacy: .public)")
      for handle in resumed { follow(handle) }
    } catch {
      Self.logger.error("Interrupted job attempts could not be resumed code=\(error.code, privacy: .public)")
    }
  }

  private func wait(for request: AIConsentRequest, engine: JobEngine) {
    consentNeeded = request
    drain(engine)
  }

  /// Observes the queue together with the consent it waits for, so a grant made anywhere, a chat's consent sheet included, starts it again; the store
  /// publishes a read only when it changed, which makes a refused start one try per distinct queue. A drain started again waits for the one before it,
  /// which ends once the job it runs has ended, so jobs still start one at a time.
  private func drain(_ engine: JobEngine) {
    let previous = draining
    previous?.cancel()
    let (store, replica) = (store, store.replica)
    draining = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, self != nil else { return }
      let waiting = self?.consentNeeded
      do {
        for try await queue in store.observeReads({ transaction in try JobQueue(replica: replica, waiting: waiting, in: transaction) }) {
          guard let self, !Task.isCancelled else { return }
          if queue.consented == true { self.consentNeeded = nil }
          guard let request = await self.start(queue.jobs, on: engine) else { continue }
          self.wait(for: request, engine: engine)
          return
        }
      } catch is CancellationError {
        return
      } catch {
        Self.logger.error("Stopped following the jobs this device asked for")
      }
    }
  }

  /// One at a time, each job once per distinct queue; answers the consent a refused start waits for, after which nothing starts until it is given.
  private func start(_ jobs: [EntityRef], on engine: JobEngine) async -> AIConsentRequest? {
    for job in jobs {
      guard consentNeeded == nil, !Task.isCancelled else { return nil }
      do throws(JobEngineError) {
        let handle = try await starter(engine, job)
        follow(handle)
        _ = await handle.result
      } catch .consentRequired(let request) {
        return request
      } catch {
        Self.logger.notice("A job this device asked for did not start code=\(error.code, privacy: .public)")
      }
    }
    return nil
  }
}
