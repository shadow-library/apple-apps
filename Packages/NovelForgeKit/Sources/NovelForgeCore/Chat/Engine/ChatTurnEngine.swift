import Foundation
import OSLog
import ShadowAI
import ShadowCore
import ShadowStore
import Synchronization

/// Runs chat turns on this device (apps/novel-forge-server/src/modules/refinement/chat.service.ts:268-411). Everything up to saving the author's message is
/// checked first and refused with a `ChatTurnError`, writing nothing; from then on the turn runs in the background and ends in its reply, or as failed,
/// cancelled or interrupted on its local turn row. Model calls, validation and decoding run off the caller's actor.
public final class ChatTurnEngine: Sendable {
  static let logger = Logger(category: "chat.turn")

  struct Timing: Sendable {
    /// How often a running turn writes its frames between rounds; every store write wakes every observer.
    let flushInterval: Duration
    /// Milliseconds on a monotonic clock, for the trace.
    let monotonic: @Sendable () -> Double
    let now: @Sendable () -> Date

    static let standard = Timing(flushInterval: .seconds(3), monotonic: { ProcessInfo.processInfo.systemUptime * 1000 }, now: { Date() })
  }

  /// Where a run can be made to end as a crash ends it, or to fail a write, so recovery can be checked at every step.
  struct Faults: Sendable {
    enum Point: Sendable {
      case settled
      case staged
      case appending
      case ending
    }

    enum Fault: Sendable {
      case crash
      case failure
    }

    let inject: @Sendable (Point) -> Fault?
    /// Runs the stop write that `cancel` starts, so a test can hold it until a later run of the turn began.
    var stopWrite: @Sendable (_ write: @Sendable () async -> Void) async -> Void = { await $0() }

    static let none = Faults { _ in nil }
  }

  enum Stop: Sendable {
    case cancelled
    case interrupted
  }

  final class Control: Sendable {
    let session: UUID
    private let state = Mutex<(stop: Stop?, task: Task<ChatTurnOutcome, Never>?, stream: ChatTurnStream?)>((nil, nil, nil))

    init(session: UUID) {
      self.session = session
    }

    var stop: Stop? { state.withLock { $0.stop } }

    var stream: ChatTurnStream? { state.withLock { $0.stream } }

    func attach(_ task: Task<ChatTurnOutcome, Never>, stream: ChatTurnStream) {
      let stopped = state.withLock { state in
        state.task = task
        state.stream = stream
        return state.stop != nil
      }
      if stopped { task.cancel() }
    }

    func stop(_ reason: Stop) {
      let task = state.withLock { state -> Task<ChatTurnOutcome, Never>? in
        if state.stop == nil { state.stop = reason }
        return state.task
      }
      task?.cancel()
    }
  }

  let store: VaultStore
  let router: @Sendable () async -> TaskRouter
  let consent: AIConsentRequirement
  let upkeep: ChatSessionUpkeep
  let grace: any ChatTurnGrace
  let timing: Timing
  let faults: Faults
  /// Whether a turn may be written unrestricted; the app takes the build's flag (orchestrator decision 5).
  let unrestrictedAvailable: Bool
  private let running = Mutex<[UUID: Control]>([:])

  init(
    store: VaultStore, router: @escaping @Sendable () async -> TaskRouter, consent: AIConsentRequirement, upkeep: ChatSessionUpkeep,
    grace: any ChatTurnGrace = NoChatTurnGrace(), timing: Timing = .standard, faults: Faults = .none, unrestrictedAvailable: Bool = UnrestrictedWriting.isAvailable
  ) {
    self.store = store
    self.router = router
    self.consent = consent
    self.upkeep = upkeep
    self.grace = grace
    self.timing = timing
    self.faults = faults
    self.unrestrictedAvailable = unrestrictedAvailable
  }

  /// `router` builds the router for each turn, so a change to the AI settings holds from the next turn; `consent` is what a chat turn sends.
  public convenience init(
    store: VaultStore, router: @escaping @Sendable () async -> TaskRouter, consent: AIConsentRequirement, grace: any ChatTurnGrace = NoChatTurnGrace()
  ) {
    self.init(store: store, router: router, consent: consent, upkeep: .vault(store), grace: grace)
  }

  /// Sends the author's message: refuses it with nothing written, or saves it with its local turn and returns the running turn.
  @concurrent
  public func send(
    _ content: String, passages: [ChatTurnPassage] = [], session: UUID, novel: UUID, choices: ChatTurnChoices = ChatTurnChoices()
  ) async throws(ChatTurnError) -> ChatTurnHandle {
    try await begin(.new(content: content, passages: passages, choices: choices), session: session, novel: novel, turn: UUID())
  }

  /// Answers an author message of the transcript that has no reply here, as `Answer here` does for a message another device is answering (orchestrator
  /// decision 6): both replies stand. The message's recorded choices and passages are used as they were sent.
  @concurrent
  public func answer(message: UUID, session: UUID, novel: UUID) async throws(ChatTurnError) -> ChatTurnHandle {
    try await begin(.existing(message), session: session, novel: novel, turn: UUID())
  }

  /// Tries a failed or stopped turn of this device again under the same id. A turn that had settled its answer is finished from it, so changes it may have
  /// applied are never applied twice; any other asks again over the conversation as it stands.
  @concurrent
  public func retry(turn: UUID) async throws(ChatTurnError) -> ChatTurnHandle {
    let (local, record) = try await storeCall { () async throws(StoreError) in
      (try await store.localTurn(turn), try await store.read { transaction in try ChatTurnRecords.load(turn, in: transaction.database) })
    }
    guard let local, local.state != .pending, local.replica == store.replica else { throw .turnNotRetryable }
    try await standing(session: local.session, novel: local.novel)
    guard let record, let settled = record.settled else {
      return try await begin(.existing(local.userMessage), session: local.session, novel: local.novel, turn: turn)
    }
    let control = try reserve(turn, session: local.session)
    do throws(ChatTurnError) {
      let replica = store.replica
      let now = timing.now()
      try await storeCall { () async throws(StoreError) in
        try await store.write { transaction in
          try LocalTurnStore.begin(turn, novel: local.novel, session: local.session, userMessage: local.userMessage, replica: replica, at: now, in: transaction.database)
          try ChatTurnRecords.save(record.basis, in: transaction.database)
          if let staged = record.staged { try ChatTurnRecords.stage(turn, staged, in: transaction.database) }
          try ChatTurnRecords.settle(turn, settled, in: transaction.database)
        }
      }
    } catch {
      release(turn)
      throw error
    }
    let run = ChatTurnRun(
      engine: self, basis: record.basis, control: control, call: nil, checkpoint: nil, settled: settled, staged: record.staged, after: 0, sources: [])
    let router = await router()
    return start(run, opening: [.user(message: local.userMessage)], titled: record.basis.namesSession ? router : nil)
  }

  /// Resumes a pending turn of this device that is not running, as one the system stopped in the background: a reset voids what it had shown, and it asks
  /// again from its last saved round.
  @concurrent
  public func resume(turn: UUID) async throws(ChatTurnError) -> ChatTurnHandle {
    let local = try await storeCall { () async throws(StoreError) in try await store.localTurn(turn) }
    guard let local, local.state == .pending, local.replica == store.replica, !isRunning(turn) else { throw .turnNotRetryable }
    return try await resume(local)
  }

  /// At launch: runs the card actions an apply left pending, clears what this device kept of chats deleted elsewhere, ends cancelled every turn the author
  /// stopped before its end was written, resumes every other interrupted turn it can, and fails the rest (CHT_013) so none shows as running for ever.
  @concurrent
  public func resumeInterruptedTurns() async throws(StoreError) -> [ChatTurnHandle] {
    await resumeInterruptedActions()
    try await upkeep.forgetRemovedChats()
    let busy = running.withLock { Set($0.values.map(\.session)) }
    var resumable = [LocalTurn]()
    var stopped = Set<UUID>()
    for turn in try await store.pendingLocalTurns().reversed() where !busy.contains(turn.session) {
      let record = try await store.read { transaction in try ChatTurnRecords.load(turn.id, in: transaction.database) }
      // a settled answer is appended whatever the author asks after it (ChatTurnRun.execute), so its stop is not kept
      if turn.stopped, record?.settled == nil {
        stopped.insert(turn.id)
      } else if record != nil, !resumable.contains(where: { $0.session == turn.session }) {
        resumable.append(turn)
      }
    }
    let (replica, kept, now) = (store.replica, Set(resumable.map(\.id)), timing.now())
    try await store.write { [self, stopped] transaction in
      // the running set is read inside the write, so a turn begun meanwhile is either running here or has no row yet
      let running = runningTurns()
      for turn in stopped.subtracting(running) { try LocalTurnStore.end(turn, as: .cancelled, at: now, in: transaction.database) }
      try LocalTurnStore.failStale(replica: replica, except: kept.union(running), at: now, in: transaction.database)
      try ChatTurnRecords.forgetOrphans(in: transaction.database)
    }
    var handles = [ChatTurnHandle]()
    for turn in resumable {
      do throws(ChatTurnError) {
        handles.append(try await resume(turn))
      } catch {
        Self.logger.notice("Did not resume an interrupted turn code=\(error.code, privacy: .public)")
      }
    }
    return handles
  }

  /// At launch, before any turn resumes: runs what is pending of the actions of every card apply this device stopped between its content and its actions,
  /// as that apply would have (F16). Never throws; a row it cannot finish is kept for a later launch, up to `PendingActions.attemptLimit` sweeps.
  @concurrent
  @discardableResult
  func resumeInterruptedActions() async -> [PendingActionResume] {
    let resumes = await store.resumePendingActions()
    for resume in resumes {
      switch resume {
      case .resumed: continue
      case .forgotten(_, let code): Self.logger.notice("Forgot the actions of a card not found here code=\(code, privacy: .public)")
      case .faulted(_, let code), .unreadable(let code): Self.logger.notice("Did not finish an interrupted card's actions code=\(code, privacy: .public)")
      case .skipped(_, let fault): Self.logger.notice("Skipped a faulted card's actions code=\(fault ?? "-", privacy: .public)")
      }
    }
    return resumes
  }

  /// The turn's events from its first stored frame, then live while it runs here; a turn not running here replays what it stored. Every caller gets
  /// its own stream, so a view that reopens follows the turn again.
  @concurrent
  public func observe(turn: UUID) async throws(StoreError) -> AsyncStream<TurnStreamEvent> {
    let stream = control(turn)?.stream
    let start = stream?.startSequence ?? .max
    let stored = try await store.localTurnFrames(turn).filter { $0.sequence <= start }.compactMap(\.decoded)
    if let stream { return stream.subscribe(after: stored) }
    let (events, continuation) = AsyncStream.makeStream(of: TurnStreamEvent.self)
    for event in stored { continuation.yield(event) }
    continuation.finish()
    return events
  }

  /// The author stops the turn: it ends cancelled once whatever it is writing settles; an answer it already settled is still appended. The stop is written
  /// at once, with the frames not yet stored, so a process that ends before the turn records its end leaves it to end cancelled at the next launch.
  public func cancel(turn: UUID) {
    guard let control = control(turn) else { return }
    control.stop(.cancelled)
    guard control.stop == .cancelled else { return }
    let (faults, now) = (faults, timing.now())
    Task.detached(priority: .userInitiated) { [self] in
      await faults.stopWrite { await self.writeStop(turn, control: control, at: now) }
    }
  }

  private func writeStop(_ turn: UUID, control: Control, at now: Date) async {
    let (stream, session) = (control.stream, control.session)
    let taken = Mutex<ChatTurnStream.Pending?>(nil)
    do throws(StoreError) {
      try await store.write { [self] transaction in
        // a later run of the turn, begun before this write, is not the one the author stopped
        guard self.control(turn).map({ $0 === control }) ?? true else { return }
        // taken inside the write, so the run's own end, written before or after it, never drops frames this took
        let pending = stream?.take()
        taken.withLock { $0 = pending }
        if let pending { try ChatTurnRun.write(pending, turn: turn, session: session, at: now, in: transaction.database) }
        try LocalTurnStore.markStopped(turn, at: now, in: transaction.database)
      }
    } catch {
      if let pending = taken.withLock({ $0 }) { stream?.requeue(pending) }
      Self.logger.notice("Could not record a stop code=\(error.code, privacy: .public)")
    }
  }

  /// Stops the turn without ending it, for the background grace's expiry; it stays pending to resume.
  public func interrupt(turn: UUID) {
    control(turn)?.stop(.interrupted)
  }

  /// The session's turn as the transcript shows it here.
  @concurrent
  public func activity(session: UUID) async throws(StoreError) -> ChatTurnActivity {
    let last = try await store.read { transaction in
      try ChatTranscript.messages(of: session, newest: 1, in: transaction).last
    }
    let status = try await store.localTurnStatus(session: session, lastMessage: last?.record?.id)
    if let pending = status.pending { return isRunning(pending.id) ? .running(pending) : .interrupted(pending) }
    if let ended = status.ended { return .ended(ended) }
    guard let record = last?.record, record.role == .known(.user) else { return .idle }
    return .answeringElsewhere(message: record.id)
  }

  // MARK: running turns

  private func begin(_ authored: ChatTurnAuthored, session: UUID, novel: UUID, turn: UUID) async throws(ChatTurnError) -> ChatTurnHandle {
    let control = try reserve(turn, session: session)
    let router = await router()
    let prepared: ChatTurnPrepared
    do throws(ChatTurnError) {
      prepared = try await prepare(authored, session: session, novel: novel, turn: turn, router: router)
      let replica = store.replica
      let now = timing.now()
      try await storeCall { () async throws(StoreError) in
        try await store.write { transaction in
          if let message = prepared.message { _ = try message.append(in: &transaction) }
          let basis = prepared.basis
          try LocalTurnStore.begin(turn, novel: novel, session: session, userMessage: basis.userMessage, replica: replica, at: now, in: transaction.database)
          try ChatTurnRecords.save(basis, in: transaction.database)
        }
      }
    } catch {
      release(turn)
      throw error
    }
    let run = ChatTurnRun(
      engine: self, basis: prepared.basis, control: control, call: prepared.call, checkpoint: nil, settled: nil, staged: nil, after: 0, sources: [])
    return start(run, opening: [.user(message: prepared.basis.userMessage)], titled: prepared.basis.namesSession ? router : nil)
  }

  /// chat.service.ts:270-271 for a turn that resumes or is tried again: its chat is still active and its novel still there.
  private func standing(session: UUID, novel: UUID) async throws(ChatTurnError) {
    let refusal = try await storeCall { () async throws(StoreError) in
      try await store.read { transaction -> ChatTurnError? in
        guard case .readable(let entry) = try ChatSessionRecord.read(id: session, in: transaction), !entry.isRemoved, entry.record.novel == novel else {
          return .sessionNotFound
        }
        guard entry.record.status == .known(.active) else { return .sessionArchived }
        guard case .readable(let novelEntry) = try NovelRecord.read(id: novel, in: transaction), !novelEntry.isRemoved else { return .novelNotFound }
        return nil
      }
    }
    if let refusal { throw refusal }
  }

  /// A pending turn that cannot resume, because its record is gone or unreadable or its chat is no longer active, ends failed; one that another run is
  /// resuming, or that shares its chat with a running turn, is left as it is.
  private func resume(_ local: LocalTurn) async throws(ChatTurnError) -> ChatTurnHandle {
    let record: ChatTurnRecord
    let control: Control
    do throws(ChatTurnError) {
      let read = try await storeCall { () async throws(StoreError) in
        try await store.read { transaction in try ChatTurnRecords.load(local.id, in: transaction.database) }
      }
      guard let read else { throw .turnNotRetryable }
      try await standing(session: local.session, novel: local.novel)
      record = read
      control = try reserve(local.id, session: local.session)
    } catch {
      if case .turnRunning = error { throw error }
      let failure = error.code == ChatTurnError.turnNotRetryable.code ? LocalTurnStore.interrupted : ChatTurnFailures.failure(error)
      _ = try? await store.endLocalTurn(local.id, as: .failed(failure), at: timing.now())
      throw error
    }
    let carry = local.checkpoint.flatMap { ChatTurnCarry(json: $0.carry) }
    let run = ChatTurnRun(
      engine: self, basis: record.basis, control: control, call: nil, checkpoint: carry == nil ? nil : local.checkpoint, settled: record.settled,
      staged: record.staged, after: local.lastSequence, sources: carry?.sources ?? [])
    // the naming that ran beside the turn may have ended with the process; it names nothing once the session has a title
    let router = await router()
    return start(run, opening: [.reset], titled: record.basis.namesSession ? router : nil)
  }

  private func start(_ run: ChatTurnRun, opening: [TurnStreamEvent], titled router: TaskRouter?) -> ChatTurnHandle {
    let events = run.stream.subscribe()
    for event in opening { run.stream.emit(event) }
    if let router { run.nameSession(router: router) }
    let task = Task.detached(priority: .userInitiated) { await run.run() }
    run.control.attach(task, stream: run.stream)
    return ChatTurnHandle(turn: run.basis.turn, userMessage: run.basis.userMessage, events: events, task: task)
  }

  private func reserve(_ turn: UUID, session: UUID) throws(ChatTurnError) -> Control {
    let control = Control(session: session)
    let reserved = running.withLock { running -> Bool in
      guard !running.values.contains(where: { $0.session == session }), running[turn] == nil else { return false }
      running[turn] = control
      return true
    }
    guard reserved else { throw .turnRunning }
    return control
  }

  func release(_ turn: UUID) {
    _ = running.withLock { $0.removeValue(forKey: turn) }
  }

  private func control(_ turn: UUID) -> Control? {
    running.withLock { $0[turn] }
  }

  private func isRunning(_ turn: UUID) -> Bool {
    control(turn) != nil
  }

  private func runningTurns() -> Set<UUID> {
    running.withLock { Set($0.keys) }
  }

  private func storeCall<T>(_ body: () async throws(StoreError) -> T) async throws(ChatTurnError) -> T {
    do {
      return try await body()
    } catch {
      throw .store(error)
    }
  }
}
