import Foundation
import OSLog
import ShadowCore
import ShadowStore
import ShadowSync
import ShadowSyncCloudKit

/// Runs sync for one vault store: `SyncStartup` works out where the vault stands, `SyncEngine` syncs on the schedule `SyncScheduler` sets,
/// and `statusUpdates()` reports the outcome. Runs never overlap: attach, detach and discovery wait for the run in flight, and every trigger
/// that arrives during a run joins one follow-up run.
public actor SyncRuntime {
  private struct AttachedEngine {
    let location: SyncLocation
    let providerID: Int
    let provider: any StorageProvider
    let engine: SyncEngine
    let ring: KeyRing
    let recovery: RecoverySetup
    var isStarted = false
    var needsRecoveryReconcile = true
  }

  private static let logger = Logger(category: "SyncRuntime")

  private let startup: SyncStartup
  private let store: VaultStore
  private let device: ReplicaDevice
  private let trustedClock: TrustedClock
  private let configuration: SyncConfiguration
  private let wallClock: @Sendable () -> Date
  private let refresh: @Sendable () async -> Void
  private let clock: SyncSchedulerClock
  private let feed = SyncStatusFeed(.off)
  private var scheduler: SyncScheduler

  private var isStarted = false
  private var isShutDown = false
  private var isBusy = false
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var timer: Task<Void, Never>?
  private var timerGeneration = 0
  private var listeners: [Task<Void, Never>] = []
  private var listenedProvider: Int?

  private var phase: SyncPhase?
  private var engine: AttachedEngine?
  private var attention = SyncAttentionSlots()
  private var isCatchingUp = false
  private var isIncludedInBackup = false
  private var writes = 0
  private var uploadedWrites = 0
  private var lastMaintenance: Duration?
  private var lastFailureWasUnreachable = false
  private(set) var completedRuns = 0

  /// `store` must have been opened with `SyncEngine.migrations` and `SyncEngine.wallClock(preferring: trustedClock)`. `refresh` runs first on
  /// every foreground, as when the app asks CloudKit's sync engine to fetch.
  public init<C: Clock>(
    environment: SyncStartupEnvironment,
    store: VaultStore,
    device: ReplicaDevice,
    trustedClock: TrustedClock,
    configuration: SyncConfiguration = .init(),
    policy: SyncSchedulePolicy = .init(),
    clock: C = ContinuousClock(),
    wallClock: @escaping @Sendable () -> Date = { Date() },
    refresh: @escaping @Sendable () async -> Void = {}
  ) where C.Duration == Duration {
    startup = SyncStartup(environment)
    self.store = store
    self.device = device
    self.trustedClock = trustedClock
    self.configuration = configuration
    self.wallClock = wallClock
    self.refresh = refresh
    self.clock = SyncSchedulerClock(clock)
    scheduler = SyncScheduler(policy: policy)
  }

  deinit {
    timer?.cancel()
    for listener in listeners { listener.cancel() }
    feed.finish()
  }

  public nonisolated var status: SyncStatus { feed.current }

  /// The current status first, then every change in order.
  public nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
    feed.stream()
  }

  public var currentPhase: SyncPhase? { phase }

  /// The launch run; nothing runs before it. Returns once the runtime is idle.
  public func start() async {
    guard !isShutDown else { return }
    if !isStarted {
      isStarted = true
      scheduler.request(.launch)
    }
    await settle()
  }

  public func foreground() async {
    scheduler.enterForeground(at: clock.now())
    await settle()
  }

  /// Stops every timer and uploads what is still unsent; returns once that upload is done, so the app can end its background task.
  public func background() async {
    scheduler.enterBackground()
    cancelTimer()
    await settle()
  }

  public func localWrite() {
    guard phase?.canSync ?? true else { return }
    writes += 1
    scheduler.localWrite(at: clock.now())
    pump()
  }

  /// A hint that storage changed, such as a silent push; returns once the sync it starts is done.
  public func changeNotice() async {
    noteChange()
    await untilIdle()
  }

  public func discover(_ settings: SyncProviderSettings) async throws(SyncStartupError) -> VaultDiscovery {
    await acquire()
    defer { release() }
    return try await startup.discover(settings)
  }

  /// The explicit "Create a vault here" or "Join the vault found here"; also turns sync back on after `detach()` or unreadable settings.
  public func attach(_ settings: SyncProviderSettings, choice: VaultChoice) async throws(SyncStartupError) -> SyncPhase {
    await acquire()
    defer { release() }
    let result = try await startup.attach(settings, choice: choice)
    scheduler.reset()
    if let retry = apply(result) { scheduler.finish(retry, performed: [], at: clock.now()) }
    if result.phase.canSync { scheduler.request(.launch) }
    return result.phase
  }

  /// Turns sync off for good and returns the vault to device backups; its files and keys stay at the location.
  public func detach() async throws(SyncStartupError) {
    await acquire()
    defer { release() }
    try await startup.detach()
    phase = .detached
    scheduler.reset()
    stop(nil, cadence: .idle)
    listen()
    isIncludedInBackup = false
    includeInBackup()
    uploadedWrites = writes
    publish()
  }

  /// Cancels the timers and listeners and ends the status stream; a run in flight finishes, and calls waiting for it return after it.
  public func shutdown() {
    isShutDown = true
    cancelTimer()
    listen()
    feed.finish()
  }

  func settle() async {
    pump()
    await untilIdle()
  }

  func idle() async {
    await untilIdle()
  }

  var exclusiveWaiterCount: Int { lockWaiters.count }

  var recoverySetup: RecoverySetup? { engine?.recovery }

  func noteChange() {
    scheduler.request(.sync)
    pump()
  }

  private func noteCondition(_ condition: CloudKitStorageCondition) async {
    await acquire()
    if case .failed = applyCondition(condition) { scheduler.request(.launch) }
    release()
  }

  private func pump() {
    guard !isBusy else { return }
    if isStarted, !isShutDown, let work = scheduler.takeDue(at: clock.now()) {
      isBusy = true
      cancelTimer()
      publish()
      Task { await self.run(work) }
      return
    }
    armTimer()
    publish()
    resumeIdleWaiters()
  }

  private func run(_ work: SyncWork) async {
    lastFailureWasUnreachable = false
    let result = await perform(work)
    isCatchingUp = false
    completedRuns += 1
    scheduler.finish(result, performed: work, at: clock.now())
    switch result {
    case .completed:
      attention.transient = nil
    case .failed, .rateLimited:
      let failures = scheduler.consecutiveFailures
      if lastFailureWasUnreachable, failures >= scheduler.policy.unreachableAfterFailures { attention.transient = .storageUnreachable }
      Self.logger.info("Sync run will retry failures=\(failures, privacy: .public)")
    }
    release()
  }

  private func perform(_ work: SyncWork) async -> SyncRunResult {
    if work.contains(.refresh) { await refresh() }
    isCatchingUp = work.contains(.evaluate)
    if work.contains(.evaluate) || phase == nil, let result = await evaluate() { return result }
    guard phase?.canSync == true, engine != nil else { return .completed }
    if let result = await startEngine() { return result }
    guard let attached = engine else { return .completed }
    if work.contains(.download), let result = await download(with: attached) { return result }
    if work.contains(.upload), let result = await upload(with: attached) { return result }
    if work.contains(.evaluate), let result = await maintain(with: attached) { return result }
    return .completed
  }

  private func evaluate() async -> SyncRunResult? {
    let result: SyncStartupResult
    do {
      result = try await startup.evaluate()
    } catch {
      return await failure(of: error)
    }
    return apply(result)
  }

  private func apply(_ result: SyncStartupResult) -> SyncRunResult? {
    apply(result.phase, attachment: result.attachment)
  }

  /// Returns the retry of a phase that passes on its own, nil otherwise.
  private func apply(_ phase: SyncPhase, attachment: SyncAttachment? = nil) -> SyncRunResult? {
    self.phase = phase
    defer {
      listen()
      publish()
    }
    switch phase {
    case .vault(.ready), .vault(.partiallyReadable):
      guard let attachment else { return .failed(retry: .launch) }
      if engine?.location != attachment.location || engine?.providerID != attachment.providerID {
        let made = attachment.engine(store: store, device: device, trustedClock: trustedClock, configuration: configuration, wallClock: wallClock)
        engine = AttachedEngine(
          location: attachment.location, providerID: attachment.providerID, provider: attachment.provider, engine: made, ring: attachment.ring,
          recovery: attachment.recoverySetup(store: store, wallClock: wallClock))
      }
      attention.phase = nil
      if case .vault(.partiallyReadable(_, let missing)) = phase { attention.download = .keysMissing(replicas: Set(missing.values.joined())) }
      scheduler.setCadence(.polling, at: clock.now())
    case .vault(.awaitingKey):
      stop(.awaitingKey, cadence: .awaitingKey)
    case .vault(.noStorageAccount), .vault(.noVault), .detached:
      stop(nil, cadence: .idle)
      includeInBackup()
    case .deviceLocked, .accountUnavailable:
      attention = SyncAttentionSlots(phase: SyncAttentionReason(phase: phase))
      scheduler.setCadence(.idle, at: clock.now())
      return .failed(retry: .launch)
    case .appUpdateRequired:
      stop(.appUpdateRequired, cadence: .idle)
    case .accountChanged, .storageRemoved, .settingsUnreadable, .vaultMismatch, .vaultUnrecognized:
      stop(SyncAttentionReason(phase: phase), cadence: .idle)
      includeInBackup()
    }
    return nil
  }

  private func applyCondition(_ condition: CloudKitStorageCondition) -> SyncRunResult {
    switch condition {
    case .zoneLost(let loss):
      stop(.zoneLost(loss), cadence: .idle)
      includeInBackup()
      listen()
      publish()
      return .completed
    case .accountChanged(.signedOut):
      return apply(.accountUnavailable) ?? .completed
    case .accountChanged:
      return apply(.accountChanged) ?? .completed
    }
  }

  private func stop(_ reason: SyncAttentionReason?, cadence: SyncCadence) {
    engine = nil
    attention = SyncAttentionSlots(phase: reason)
    scheduler.setCadence(cadence, at: clock.now())
  }

  private func startEngine() async -> SyncRunResult? {
    guard let attached = engine, !attached.isStarted else { return nil }
    do throws(SyncError) {
      _ = try await attached.engine.start()
    } catch .lifecycle(.markerUnavailable) {
      if let result = await evaluate() { return result }
      guard phase?.canSync == true, let again = engine else { return .completed }
      do throws(SyncError) {
        _ = try await again.engine.start()
      } catch {
        return await failure(of: error, retry: .launch)
      }
      markStarted(again)
      return nil
    } catch {
      return await failure(of: error, retry: .launch)
    }
    markStarted(attached)
    return nil
  }

  private func markStarted(_ attached: AttachedEngine) {
    guard engine?.engine === attached.engine else { return }
    engine?.isStarted = true
    isIncludedInBackup = false
  }

  private func download(with attached: AttachedEngine) async -> SyncRunResult? {
    let heldKeys = Set(attached.ring.keyIDs)
    let outcome: SyncDownloadOutcome
    do throws(SyncError) {
      outcome = try await attached.engine.download()
    } catch {
      return await failure(of: error, retry: .sync)
    }
    guard !outcome.postponed else { return .failed(retry: .launch) }
    await startup.noteMissingKeys(outcome.missingKeys, vault: attached.location.vault)
    let replicas = Set(outcome.missingKeys.values.joined())
    attention.download = replicas.isEmpty ? nil : .keysMissing(replicas: replicas)
    publish()
    if !outcome.applied.isEmpty || !Set(attached.ring.keyIDs).subtracting(heldKeys).isEmpty { engine?.needsRecoveryReconcile = true }
    await reconcileRecovery()
    return nil
  }

  /// After a key joined the ring or a download applied files that may carry recovery records; touches storage only when a copy must be sealed or
  /// deleted, and a failure is tried again after the next download.
  private func reconcileRecovery() async {
    guard let attached = engine, attached.needsRecoveryReconcile else { return }
    do throws(RecoveryError) {
      _ = try await attached.recovery.reconcile()
      if engine?.engine === attached.engine { engine?.needsRecoveryReconcile = false }
    } catch {
      Self.logger.warning("Recovery copies not reconciled code=\(error.code, privacy: .public)")
    }
  }

  private func upload(with attached: AttachedEngine) async -> SyncRunResult? {
    let written = writes
    guard await hasPendingChanges() else {
      uploadedWrites = max(uploadedWrites, written)
      return nil
    }
    let outcome: SyncUploadOutcome
    do throws(SyncError) {
      outcome = try await attached.engine.upload()
    } catch {
      return await failure(of: error, retry: .upload)
    }
    switch await attached.engine.deviceClock {
    case .wrong(let skew): attention.clock = .wrongClock(skew: skew, stopsUploads: false)
    case .correct: attention.clock = nil
    case .unchecked: break
    }
    defer { publish() }
    switch outcome {
    case .uploaded, .nothingToUpload:
      attention.upload = nil
      uploadedWrites = max(uploadedWrites, written)
      return nil
    case .awaitingKey:
      attention.upload = .writingKeyMissing
      return nil
    case .postponed:
      return .failed(retry: [.evaluate, .upload])
    }
  }

  /// Compaction and adoption run with a catch-up run at most once per `maintenanceInterval`, whatever their outcome.
  private func maintain(with attached: AttachedEngine) async -> SyncRunResult? {
    let now = clock.now()
    if let lastMaintenance, now - lastMaintenance < scheduler.policy.maintenanceInterval { return nil }
    lastMaintenance = now
    do throws(SyncError) {
      _ = try await attached.engine.compact()
      _ = try await attached.engine.adopt()
    } catch {
      return await failure(of: error, retry: [])
    }
    return nil
  }

  private func hasPendingChanges() async -> Bool {
    do {
      return try await !store.pendingChanges(limit: 1).isEmpty
    } catch {
      return true
    }
  }

  private func failure(of error: SyncStartupError) async -> SyncRunResult {
    Self.logger.warning("Sync evaluation failed code=\(error.code, privacy: .public)")
    if let result = await conditionFailure() { return result }
    switch error {
    case .deviceLocked, .setup(.deviceLocked): return apply(.deviceLocked) ?? .completed
    case .accountUnavailable, .noStorageAccount: return apply(.accountUnavailable) ?? .completed
    case .setup(.storage(let storage)), .storage(let storage): return failure(of: storage, retry: .launch)
    case .setup(.newerFormat): return apply(.appUpdateRequired) ?? .completed
    case .setup(.unrecognized): return apply(.vaultUnrecognized) ?? .completed
    case .setup(.vaultMismatch(let expected, let found)): return apply(.vaultMismatch(expected: expected, found: found)) ?? .completed
    case .location:
      _ = apply(.settingsUnreadable)
      return .failed(retry: .launch)
    case .alreadyAttached, .setup, .keyRing, .marker:
      return failed(code: error.code, retry: .launch)
    }
  }

  private func failure(of error: SyncError, retry: SyncWork) async -> SyncRunResult {
    Self.logger.warning("Sync call failed code=\(error.code, privacy: .public)")
    if let result = await conditionFailure() { return result }
    if let phase = SyncPhase(failure: error) { return apply(phase) ?? .completed }
    switch error {
    case .storage(let storage):
      return failure(of: storage, retry: retry)
    case .storeClockUntrusted(let skew):
      attention.upload = .wrongClock(skew: skew, stopsUploads: true)
      return .completed
    case .lifecycle(.markerUnavailable):
      attention.phase = .deviceLocked
      return .failed(retry: .launch)
    case .notStarted:
      engine?.isStarted = false
      return .failed(retry: .launch)
    case .replicaChanged:
      return .failed(retry: retry)
    default:
      return failed(code: error.code, retry: retry)
    }
  }

  private func failure(of error: StorageError, retry: SyncWork) -> SyncRunResult {
    switch error {
    case .quotaExceeded:
      attention.upload = .quotaFull
      return retry.contains(.evaluate) ? .failed(retry: retry) : .completed
    case .rateLimited(let retryAfter):
      return .rateLimited(retryAfter: retryAfter, retry: retry)
    case .unauthenticated:
      return apply(.accountUnavailable) ?? .completed
    case .unavailable, .underlying:
      lastFailureWasUnreachable = true
      return .failed(retry: retry)
    case .notFound, .alreadyExists, .keyConflict, .tooLarge:
      return failed(code: error.code, retry: retry)
    }
  }

  private func failed(code: String, retry: SyncWork) -> SyncRunResult {
    attention.transient = .failed(code: code)
    return .failed(retry: retry)
  }

  /// Reads the attached location's provider only: a provider made to look at another location says nothing about this vault.
  private func conditionFailure() async -> SyncRunResult? {
    let attached: (any StorageProvider)?
    if let engine { attached = engine.provider } else { attached = await startup.attachedStorage()?.provider }
    guard let provider = attached as? CloudKitStorageProvider, let condition = try? await provider.condition() else { return nil }
    return applyCondition(condition)
  }

  /// Once per detached spell, so a store pinned out of backups logs its refusal once.
  private func includeInBackup() {
    guard !isIncludedInBackup else { return }
    switch StorageAttachment.detach(store) {
    case nil, .backupExclusionPinned?: isIncludedInBackup = true
    case .some: break
    }
  }

  private func listen() {
    let attached = isShutDown ? nil : engine
    guard attached?.providerID != listenedProvider else { return }
    for listener in listeners { listener.cancel() }
    listeners = []
    listenedProvider = attached?.providerID
    guard let provider = attached?.provider else { return }
    let notices = provider.changeNotices()
    listeners.append(
      Task { [weak self] in
        for await _ in notices {
          guard let self else { return }
          await self.noteChange()
        }
      })
    guard let cloudKit = provider as? CloudKitStorageProvider else { return }
    let conditions = cloudKit.conditionChanges()
    listeners.append(
      Task { [weak self] in
        for await condition in conditions {
          guard let self else { return }
          await self.noteCondition(condition)
        }
      })
  }

  private func computeStatus() -> SyncStatus {
    if let reason = attention.current { return .attentionNeeded(reason) }
    guard phase?.canSync ?? scheduler.hasDeferredWork else { return .off }
    if isCatchingUp || writes > uploadedWrites || scheduler.hasDeferredWork { return .syncing }
    return .upToDate
  }

  private func publish() {
    feed.publish(computeStatus())
  }

  private func untilIdle() async {
    guard isBusy else { return }
    await withCheckedContinuation { idleWaiters.append($0) }
  }

  private func resumeIdleWaiters() {
    let waiters = idleWaiters
    idleWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  private func acquire() async {
    guard isBusy else {
      isBusy = true
      cancelTimer()
      return
    }
    await withCheckedContinuation { lockWaiters.append($0) }
  }

  /// Hands the lock straight to the next waiter, so no run can start between two exclusive calls.
  private func release() {
    guard lockWaiters.isEmpty else {
      lockWaiters.removeFirst().resume()
      return
    }
    isBusy = false
    pump()
  }

  private func armTimer() {
    cancelTimer()
    guard isStarted, !isShutDown, let deadline = scheduler.nextDeadline() else { return }
    let generation = timerGeneration
    let sleep = clock.sleep
    timer = Task { [weak self] in
      do {
        try await sleep(deadline)
      } catch {
        return
      }
      await self?.timerFired(generation)
    }
  }

  private func cancelTimer() {
    timer?.cancel()
    timer = nil
    timerGeneration += 1
  }

  private func timerFired(_ generation: Int) {
    guard generation == timerGeneration else { return }
    timer = nil
    pump()
  }
}
