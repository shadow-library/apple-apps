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
    }

    enum Fault: Sendable {
      case crash
      case failure
    }

    let inject: @Sendable (Point) -> Fault?

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
  private let running = Mutex<[UUID: Control]>([:])

  init(
    store: VaultStore, router: @escaping @Sendable () async -> TaskRouter, consent: AIConsentRequirement, upkeep: ChatSessionUpkeep,
    grace: any ChatTurnGrace = NoChatTurnGrace(), timing: Timing = .standard, faults: Faults = .none
  ) {
    self.store = store
    self.router = router
    self.consent = consent
    self.upkeep = upkeep
    self.grace = grace
    self.timing = timing
    self.faults = faults
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
    return start(run, opening: [.user(message: local.userMessage)], titled: nil)
  }

  /// Resumes a pending turn of this device that is not running, as one the system stopped in the background: a reset voids what it had shown, and it asks
  /// again from its last saved round.
  @concurrent
  public func resume(turn: UUID) async throws(ChatTurnError) -> ChatTurnHandle {
    let local = try await storeCall { () async throws(StoreError) in try await store.localTurn(turn) }
    guard let local, local.state == .pending, local.replica == store.replica, !isRunning(turn) else { throw .turnNotRetryable }
    return try await resume(local)
  }

  /// At launch: clears what this device kept of chats deleted elsewhere, resumes every interrupted turn it can, and fails the rest (CHT_013) so none shows
  /// as running for ever.
  @concurrent
  public func resumeInterruptedTurns() async throws(StoreError) -> [ChatTurnHandle] {
    try await upkeep.forgetRemovedChats()
    let busy = running.withLock { Set($0.values.map(\.session)) }
    var resumable = [LocalTurn]()
    for turn in try await store.pendingLocalTurns().reversed() where !busy.contains(turn.session) && !resumable.contains(where: { $0.session == turn.session }) {
      let record = try await store.read { transaction in try ChatTurnRecords.load(turn.id, in: transaction.database) }
      if record != nil { resumable.append(turn) }
    }
    let (replica, kept, now) = (store.replica, Set(resumable.map(\.id)), timing.now())
    try await store.write { [self] transaction in
      // the running set is read inside the write, so a turn begun meanwhile is either running here or has no row yet
      try LocalTurnStore.failStale(replica: replica, except: kept.union(runningTurns()), at: now, in: transaction.database)
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

  /// The author stops the turn: it ends cancelled once whatever it is writing settles; an answer it already settled is still appended.
  public func cancel(turn: UUID) {
    control(turn)?.stop(.cancelled)
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
    return start(run, opening: [.user(message: prepared.basis.userMessage)], titled: prepared.namesSession ? router : nil)
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
    return start(run, opening: [.reset], titled: nil)
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
