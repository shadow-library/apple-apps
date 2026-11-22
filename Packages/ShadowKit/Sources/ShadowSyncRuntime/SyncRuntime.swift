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
  private let refusesMoves: Bool
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
  private var isHalted = false
  private var isBusy = false
  private var lockWaiters: [CheckedContinuation<Void, Never>] = []
  private var idleWaiters: [CheckedContinuation<Void, Never>] = []
  private var timer: Task<Void, Never>?
  private var timerGeneration = 0
  private var listeners: [Task<Void, Never>] = []
  private var listenedProvider: Int?

  private var phase: SyncPhase?
  private var engine: AttachedEngine?
  private var keyAttachment: SyncAttachment?
  private var attention = SyncAttentionSlots()
  private var isCatchingUp = false
  private var isIncludedInBackup = false
  private var writes = 0
  private var uploadedWrites = 0
  private var lastMaintenance: Duration?
  private var lastFailureWasUnreachable = false
  private(set) var completedRuns = 0
  private var record = SyncRunRecord()
  private var runFailureCode: String?

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
    refusesMoves = !environment.routedStores.isEmpty
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

  public var runRecord: SyncRunRecord {
    var record = record
    record.runs = completedRuns
    record.consecutiveFailures = scheduler.consecutiveFailures
    record.unsentWrites = max(0, writes - uploadedWrites)
    return record
  }

  /// Where the runtime syncs in a vault phase, awaiting a key included; nil in every other phase.
  public var attachedLocation: SyncAttachedLocation? {
    keyAttachment.map { SyncAttachedLocation(location: $0.location, classPolicy: $0.provider.capabilities.classPolicy) }
  }

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

  /// The blob's local file: held here, or fetched from the attached storage, verified and kept here. It does not wait for a sync run.
  public func fetchBlob(_ id: BlobID) async throws(BlobError) -> URL {
    if let held = try await VaultBlobs(store: store, maximumBytes: configuration.maximumBlobBytes).localURL(of: id) { return held }
    guard let attached = engine, phase?.canSync == true else { throw .notAttached }
    return try await attached.engine.fetchBlob(id)
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
    let held = keyAttachment
    keyAttachment = nil
    do {
      try await startup.detach()
    } catch {
      keyAttachment = held
      throw error
    }
    phase = .detached
    scheduler.reset()
    stop(nil, cadence: .idle)
    listen()
    isIncludedInBackup = false
    includeInBackup()
    uploadedWrites = writes
    publish()
  }

  /// Whether sync can keep keys in this build at all; see `SyncStartup.keychainUsable()`. Asked before turning sync on, while nothing is attached.
  public func keychainUsable() async -> Bool {
    await startup.keychainUsable()
  }

  /// The key services of the attached vault, which also work while the phase is awaiting a key. Waits for the run in flight when no evaluation has
  /// answered yet; throws `unavailable` for a phase that holds no attachment, and `notAttached` before the first evaluation.
  public func keyServices() async throws(SyncStartupError) -> SyncKeyAccess {
    if keyAttachment == nil { await untilIdle() }
    guard let attachment = keyAttachment else { throw phase.map { .unavailable($0) } ?? .notAttached }
    return SyncKeyAccess(
      attachment: attachment, store: store, wallClock: wallClock, standing: { [weak self] in await self?.standing(of: attachment) ?? .gone(nil) },
      imported: { [weak self] in await self?.keysImported() })
  }

  /// Moves the attached vault to `settings` with `SyncMover`, or carries on the move in progress; no run starts until it returns. After `.moved` sync goes
  /// on at the new location; after `.superseded` the phase is `vaultMoved` with the other device's notice.
  public func moveVault(to settings: SyncProviderSettings) async throws(SyncMoveError) -> SyncMoveOutcome {
    guard !refusesMoves else { throw .routedStoresUnsupported }
    await acquire()
    defer { release() }
    return try await moving { () async throws(SyncMoveError) in
      let context = try await moveContext(to: settings)
      let engine = try await startedEngine(for: context.source)
      let mover = SyncMover(
        engine: engine, attachment: context.source, target: context.target, targetProvider: context.targetProvider, locations: context.locations,
        wallClock: wallClock)
      return await rebind(after: try await mover.run())
    }
  }

  /// Follows the move recorded for the attached vault to `settings`, this device's reach of the notice's location, with `SyncMoveFollower`.
  public func followMove(to settings: SyncProviderSettings) async throws(SyncMoveError) -> SyncMoveOutcome {
    guard !refusesMoves else { throw .routedStoresUnsupported }
    await acquire()
    defer { release() }
    return try await moving { () async throws(SyncMoveError) in
      let context = try await moveContext(to: settings)
      let engine = try await startedEngine(for: context.source)
      let follower = SyncMoveFollower(
        engine: engine, source: context.source.location, target: context.target, targetProvider: context.targetProvider, locations: context.locations)
      if let closed = try follower.close() { return await rebind(after: closed) }
      return await rebind(after: try await follower.run(try await notice(of: engine, at: context.source)))
    }
  }

  /// Gives up the move or follow in progress as far as `SyncMover.abandon()` and `SyncMoveFollower.abandon()` allow; sync then goes on where it is attached.
  /// A journal that cannot be read is discarded too, unless the notice at the attached location is this database's own.
  public func abandonMove() async throws(SyncMoveError) {
    await acquire()
    defer { release() }
    try await moving { () async throws(SyncMoveError) in
      let context = try await moveContext(to: nil)
      let journal = SyncMoveJournalStore(beside: context.locations)
      let saved: SyncMoveJournal?
      do throws(SyncMoveError) {
        saved = try journal.load()
      } catch {
        guard case .journal = error else { throw error }
        try await refuseOwnNotice(at: context.source, engine: try await startedEngine(for: context.source))
        return try journal.clear()
      }
      guard case .movingOut(_, let target)? = saved else { return try journal.clear() }
      let engine = try await startedEngine(for: context.source)
      try await SyncMover(engine: engine, attachment: context.source, target: target, targetProvider: context.targetProvider, locations: context.locations).abandon()
    }
  }

  /// Stays at the attached location after another device moved the vault; see `SyncEngine.forgetMove()` for what that gives up.
  public func stayAfterMove() async throws(SyncMoveError) {
    await acquire()
    defer { release() }
    try await moving { () async throws(SyncMoveError) in
      let context = try await moveContext(to: nil)
      if let pending = try SyncMoveJournalStore(beside: context.locations).load() { throw .moveInProgress(pending) }
      let engine = try await startedEngine(for: context.source)
      do throws(SyncError) {
        try await engine.forgetMove()
      } catch {
        throw .sync(error)
      }
    }
  }

  /// Ends the runtime as `shutdown()` does, but stops sending at once: the engine halts, so only the put already issued finishes and nothing more goes up,
  /// and the run in flight skips its remaining steps. Returns once that run is over, so another runtime may take the store over.
  public func stop() async {
    isHalted = true
    engine?.engine.halt()
    shutdown()
    await untilIdle()
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

  /// Current while the runtime attaches the vault where `attachment` did, through the same provider: after an account change or a move the old provider
  /// may reach another account's or location's storage.
  private func standing(of attachment: SyncAttachment) -> SyncKeyAttachmentStanding {
    guard let keyAttachment, keyAttachment.location == attachment.location, keyAttachment.providerID == attachment.providerID else { return .gone(phase) }
    return .current
  }

  /// Keys reached the ring another way, as through a recovery or an exchange on the primary's key services: evaluates again at once rather than at the
  /// next key check.
  public func keysImported() {
    guard !isShutDown else { return }
    engine?.needsRecoveryReconcile = true
    scheduler.request(.launch)
    pump()
  }

  func noteChange() {
    scheduler.request(.sync)
    pump()
  }

  /// Stops the engine while `body` runs and evaluates again after it: a new location, a notice that stopped the move, or the move still in progress.
  private func moving<T>(_ body: () async throws(SyncMoveError) -> T) async throws(SyncMoveError) -> T {
    engine = nil
    keyAttachment = nil
    scheduler.reset()
    defer {
      phase = nil
      attention = SyncAttentionSlots()
      scheduler.request(.launch)
      publish()
    }
    return try await body()
  }

  private func rebind(after outcome: SyncMoveOutcome) async -> SyncMoveOutcome {
    if case .moved = outcome { await startup.rebound() }
    return outcome
  }

  private func moveContext(to settings: SyncProviderSettings?) async throws(SyncMoveError) -> SyncMoveContext {
    do {
      return try await startup.moveContext(to: settings)
    } catch {
      throw .startup(error)
    }
  }

  private func startedEngine(for attachment: SyncAttachment) async throws(SyncMoveError) -> SyncEngine {
    let made = attachment.engine(store: store, device: device, trustedClock: trustedClock, configuration: configuration, wallClock: wallClock)
    do {
      _ = try await made.start()
    } catch {
      throw .sync(error)
    }
    return made
  }

  /// The notice the engine recorded, or the one at the old location once the follow's re-mint cleared the record.
  private func notice(of engine: SyncEngine, at source: SyncAttachment) async throws(SyncMoveError) -> VaultMoveNotice {
    do {
      if let recorded = try await engine.recordedMove() { return recorded }
    } catch {
      throw .sync(error)
    }
    guard let stored = try await storedNotice(at: source) else { throw .source(.notFound(VaultPath.moveNotice)) }
    return stored
  }

  private func storedNotice(at source: SyncAttachment) async throws(SyncMoveError) -> VaultMoveNotice? {
    let data: Data
    do {
      data = try await source.provider.get(VaultPath.moveNotice)
    } catch {
      guard case .notFound = error else { throw .source(error) }
      return nil
    }
    do {
      return try VaultMoveNoticeCodec.open(data, vault: source.vault) { source.ring.key($0) }
    } catch {
      throw .noticeUnreadable
    }
  }

  /// A notice is this database's own when it names the replica syncing now, or one whose chain of successors ends there.
  private func refuseOwnNotice(at source: SyncAttachment, engine: SyncEngine) async throws(SyncMoveError) {
    guard let notice = try await storedNotice(at: source) else { return }
    let directory: ReplicaDirectory
    do {
      directory = try await source.lifecycle(store: store, device: device, wallClock: wallClock).directory()
    } catch {
      throw .sync(.lifecycle(error))
    }
    var current = notice.to
    var visited: Set<ReplicaID> = []
    while current != engine.replica, visited.insert(current).inserted, let entry = directory.entry(for: current), entry.state == .retired, let next = entry.successor {
      current = next
    }
    if current == engine.replica { throw .alreadyMoved(notice) }
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
    runFailureCode = nil
    let result = await perform(work)
    isCatchingUp = false
    completedRuns += 1
    scheduler.finish(result, performed: work, at: clock.now())
    switch result {
    case .completed:
      attention.transient = nil
      record.lastSucceeded = wallClock()
    case .failed, .rateLimited:
      record.failedRuns += 1
      record.lastFailed = wallClock()
      record.lastFailureCode = runFailureCode
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
    if let notice = try? await attached.engine.recordedMove() { return apply(.vaultMoved(notice)) ?? .completed }
    if work.contains(.download), let result = await download(with: attached) { return result }
    guard !isHalted else { return .completed }
    if work.contains(.upload), let result = await upload(with: attached) { return result }
    guard !isHalted else { return .completed }
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
    if case .vault = phase { keyAttachment = attachment } else { keyAttachment = nil }
    defer {
      listen()
      publish()
    }
    switch phase {
    case .vault(.ready), .vault(.partiallyReadable):
      guard let attachment else { return .failed(retry: .launch) }
      if engine?.location != attachment.location || engine?.providerID != attachment.providerID {
        let made = attachment.engine(store: store, device: device, trustedClock: trustedClock, configuration: configuration, wallClock: wallClock)
        if isHalted { made.halt() }
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
    case .accountChanged, .storageRemoved, .settingsUnreadable, .keychainUnavailable, .vaultMismatch, .vaultUnrecognized:
      stop(SyncAttentionReason(phase: phase), cadence: .idle)
      includeInBackup()
    case .vaultMoved, .moveInProgress:
      stop(SyncAttentionReason(phase: phase), cadence: .idle)
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
    await startup.noteMissingKeys(outcome.missingKeys, vault: attached.ring.vault)
    if let notice = outcome.moved { return apply(.vaultMoved(notice)) ?? .completed }
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

  /// A blob waiting to upload counts, so a queue left by an earlier launch resumes without a new write.
  private func hasPendingChanges() async -> Bool {
    do {
      guard try await store.pendingChanges(limit: 1).isEmpty else { return true }
      return try await VaultBlobs.hasPendingUploads(in: store)
    } catch {
      return true
    }
  }

  private func failure(of error: SyncStartupError) async -> SyncRunResult {
    Self.logger.warning("Sync evaluation failed code=\(error.code, privacy: .public)")
    runFailureCode = error.code
    if let result = await conditionFailure() { return result }
    switch error {
    case .deviceLocked, .setup(.deviceLocked): return apply(.deviceLocked) ?? .completed
    case .keychainUnavailable, .keyRing(.keychainUnavailable), .setup(.keyRing(.keychainUnavailable)): return apply(.keychainUnavailable) ?? .completed
    case .accountUnavailable, .noStorageAccount: return apply(.accountUnavailable) ?? .completed
    case .setup(.storage(let storage)), .storage(let storage): return failure(of: storage, retry: .launch)
    case .setup(.newerFormat): return apply(.appUpdateRequired) ?? .completed
    case .setup(.unrecognized): return apply(.vaultUnrecognized) ?? .completed
    case .setup(.vaultMismatch(let expected, let found)): return apply(.vaultMismatch(expected: expected, found: found)) ?? .completed
    case .location:
      _ = apply(.settingsUnreadable)
      return .failed(retry: .launch)
    case .alreadyAttached, .setup, .keyRing, .marker, .notAttached, .unavailable:
      return failed(code: error.code, retry: .launch)
    }
  }

  private func failure(of error: SyncError, retry: SyncWork) async -> SyncRunResult {
    Self.logger.warning("Sync call failed code=\(error.code, privacy: .public)")
    runFailureCode = error.code
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
    case .vaultMoved:
      guard let notice = try? await engine?.engine.recordedMove() else { return apply(.moveInProgress) ?? .completed }
      return apply(.vaultMoved(notice)) ?? .completed
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
    guard let provider = attached.map(Self.storage) as? CloudKitStorageProvider, let condition = try? await provider.condition() else { return nil }
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
    guard let cloudKit = Self.storage(provider) as? CloudKitStorageProvider else { return }
    let conditions = cloudKit.conditionChanges()
    listeners.append(
      Task { [weak self] in
        for await condition in conditions {
          guard let self else { return }
          await self.noteCondition(condition)
        }
      })
  }

  /// A route's storage is the primary's seen through its prefix; the storage's own conditions are the primary's too.
  private static func storage(_ provider: any StorageProvider) -> any StorageProvider {
    (provider as? RoutedStorageProvider)?.base ?? provider
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

public struct SyncAttachedLocation: Sendable, Equatable {
  public let location: SyncLocation
  public let classPolicy: StorageClassPolicy
}
