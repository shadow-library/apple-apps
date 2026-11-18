import Foundation
import OSLog
import ShadowCore
import ShadowStore
import Synchronization

public enum AttemptResult: Sendable, Hashable {
  case settled(AttemptSettlement)
  /// Ended as a crash ends it: the attempt keeps its checkpoint here and resumes from it at the next `resumeInterrupted`.
  case interrupted
}

public struct AttemptHandle: Sendable {
  public let attempt: AttemptID
  public let job: EntityRef
  let task: Task<AttemptResult, Never>

  public var result: AttemptResult {
    get async { await task.value }
  }
}

/// One runner per vault: its running set is what keeps a second attempt of a job from starting or resuming on this device.
public final class AttemptRunner: Sendable {
  static let logger = Logger(category: "jobs.runner")

  struct Timing: Sendable {
    let heartbeat: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    static let standard = Timing(heartbeat: LeaseTerms.heartbeat) { try await Task.sleep(for: $0) }
  }

  /// Where a run can be made to end as a crash ends it, so recovery can be checked at every boundary.
  struct Faults: Sendable {
    enum Point: Sendable, Hashable {
      /// After the attempt's `write`th runner write commits, counted from its start.
      case committed(write: Int)
      case beforeCommit(step: Int)
      case afterCommit(step: Int)
      /// Inside the step's call-opening transaction, before it commits; the step is left running and its transaction commits.
      case call(step: Int)
      case renewing
      case renewed
      case settling
    }

    let crashes: @Sendable (Point) -> Bool

    static let none = Faults { _ in false }
  }

  let store: VaultStore
  let clock: LeaseClock
  let timing: Timing
  let faults: Faults
  private let running = Mutex<[AttemptID: AttemptControl]>([:])

  public convenience init(store: VaultStore, clock: LeaseClock) {
    self.init(store: store, clock: clock, timing: .standard, faults: .none)
  }

  init(store: VaultStore, clock: LeaseClock, timing: Timing, faults: Faults) {
    self.store = store
    self.clock = clock
    self.timing = timing
    self.faults = faults
  }

  public var runningAttempts: [AttemptID] {
    running.withLock { Array($0.keys) }
  }

  /// Refused when this device already holds a run of the job, so the caller resumes that one instead.
  public func start(job: EntityRef, pipeline: AttemptPipeline, input: JSONValue, pinned: JSONValue = .null, byHand: Bool = false) async throws(JobRunError) -> AttemptHandle {
    guard pipeline.steps[pipeline.first] != nil else { throw .unknownStep(pipeline.first) }
    let now = clock.now()
    let id: AttemptID
    do {
      id = try AttemptID(UUID.v7(at: now.date))
    } catch {
      preconditionFailure("UUID.v7 makes a version 7 UUID")
    }
    let control = AttemptControl(job: job)
    try reserve(id, control)
    let start = AttemptStart(job: job, replica: store.replica, started: now, byHand: byHand, pinned: pinned)
    let checkpoint = LocalCheckpoint(attempt: id, index: 0, next: pipeline.first, state: input)
    let begun: (record: AttemptRecord, job: JobRecord)
    do {
      begun = try await write(control) { transaction in
        guard let snapshot = try JobSnapshot.load(job, in: transaction) else { throw JobRunError.jobUnreadable(job) }
        if let held = try JobsLocal.runs(of: start.replica, in: transaction.database).first(where: { $0.job == job }) {
          throw JobRunError.alreadyRunningHere(held.attempt)
        }
        let first = AttemptStep(name: pipeline.first, index: 0)
        let prospective = AttemptRecord(id: id, start: start, lease: .granted(at: now), step: first, calls: [], outcome: .running, error: nil)
        switch AttemptVerdict(for: prospective, in: snapshot, at: now) {
        case .proceed: break
        case .cancel: throw JobRunError.jobCancelled(job)
        case .standDown(.succeeded): throw JobRunError.jobSucceeded(job)
        case .standDown(.outranked(let leader)): throw JobRunError.anotherAttemptLive(leader)
        }
        let record = try AttemptRecords.start(id, start, step: first, in: &transaction)
        let run = LocalRun(attempt: id, job: job, replica: start.replica, startedAt: now.date, stop: nil)
        try JobsLocal.begin(run, checkpoint: checkpoint, at: now.date, in: transaction.database)
        return (record, snapshot.job)
      }
    } catch {
      release(id)
      throw error
    }
    return launch(AttemptRun(runner: self, record: begun.record, job: begun.job, pipeline: pipeline, control: control), from: checkpoint)
  }

  /// An attempt whose kind `pipeline` does not know is left for a launch that does (apps/novel-forge-server/src/modules/jobs/job.executor.ts:135-139).
  public func resumeInterrupted(pipeline: @escaping @Sendable (JobRecord) -> AttemptPipeline?) async throws(JobRunError) -> [AttemptHandle] {
    try await resume(where: { _ in true }, pipeline: pipeline)
  }

  /// `resumeInterrupted` for one attempt, as `start` answers `alreadyRunningHere` for a run this device holds but is not running: nil when the attempt is
  /// running here or its run settled, was forgotten or was left for a launch that knows its kind.
  public func resume(_ attempt: AttemptID, pipeline: @escaping @Sendable (JobRecord) -> AttemptPipeline?) async throws(JobRunError) -> AttemptHandle? {
    try await resume(where: { $0.attempt == attempt }, pipeline: pipeline).first
  }

  private func resume(
    where included: @escaping @Sendable (LocalRun) -> Bool, pipeline: @escaping @Sendable (JobRecord) -> AttemptPipeline?
  ) async throws(JobRunError) -> [AttemptHandle] {
    let replica = store.replica
    let now = clock.now()
    let reserved = Mutex<[AttemptID]>([])
    let resumable: [Resumable]
    do {
      resumable = try await storeWrite { transaction in
        try JobsLocal.cleanup(keeping: replica, in: transaction.database)
        var resumable: [Resumable] = []
        for run in try JobsLocal.runs(of: replica, in: transaction.database) where included(run) && !self.isRunning(run.attempt) {
          switch try Self.resumption(of: run, by: replica, pipeline: pipeline, in: transaction) {
          case .resume(let entry):
            do {
              try self.reserve(run.attempt, entry.control)
            } catch {
              try Self.settle(run.attempt, .stoodDown, by: replica, in: &transaction)
              continue
            }
            reserved.withLock { $0.append(run.attempt) }
            try AttemptRecords.update(run.attempt, AttemptUpdate(lease: .granted(at: now)), by: replica, in: &transaction)
            resumable.append(entry)
          case .settle(let settlement):
            try Self.settle(run.attempt, settlement, by: replica, in: &transaction)
          case .forget:
            try JobsLocal.forget(run.attempt, in: transaction.database)
          case .leave:
            continue
          }
        }
        return resumable
      }
    } catch {
      for id in reserved.withLock({ $0 }) { release(id) }
      throw error
    }
    return resumable.map { entry in
      launch(AttemptRun(runner: self, record: entry.record, job: entry.job, pipeline: entry.pipeline, control: entry.control), from: entry.checkpoint)
    }
  }

  /// Requests the job's cancel and marks this device's attempts of it stopped in the same transaction, then aborts their steps.
  public func cancel(job: EntityRef) async throws(JobRunError) -> JobCancelOutcome {
    let replica = store.replica
    let now = clock.now()
    let outcome = try await storeWrite { transaction in
      let outcome = try JobRecords.cancel(job, in: &transaction)
      guard outcome != .alreadySucceeded else { return outcome }
      for run in try JobsLocal.runs(of: replica, in: transaction.database) where run.job == job {
        try JobsLocal.markStopped(run.attempt, as: .cancelled, at: now.date, in: transaction.database)
      }
      return outcome
    }
    guard outcome != .alreadySucceeded else { return outcome }
    for control in running.withLock({ Array($0.values) }) where control.job == job { control.stop(.cancelled) }
    return outcome
  }

  private struct Resumable: Sendable {
    let record: AttemptRecord
    let job: JobRecord
    let pipeline: AttemptPipeline
    let checkpoint: LocalCheckpoint
    let control: AttemptControl
  }

  private enum Resumption {
    case resume(Resumable)
    case settle(AttemptSettlement)
    case forget
    case leave
  }

  private static func resumption(
    of run: LocalRun, by replica: ReplicaID, pipeline: (JobRecord) -> AttemptPipeline?, in transaction: borrowing WriteTransaction
  ) throws -> Resumption {
    guard let record = try AttemptRecords.read(run.attempt, in: transaction).record, record.outcome == .running, record.start.replica == replica,
      let snapshot = try JobSnapshot.load(run.job, in: transaction)
    else { return .forget }
    if let stop = run.stop { return .settle(stop.settlement) }
    guard let checkpoint = try JobsLocal.checkpoint(run.attempt, in: transaction.database) else {
      return .settle(.failed(AttemptFailure(code: "job_run.checkpoint_unreadable", message: "The attempt's checkpoint on this device cannot be read.")))
    }
    guard let pipeline = pipeline(snapshot.job) else { return .leave }
    guard pipeline.steps[checkpoint.next] != nil else { return .settle(.failed(AttemptFailure(JobRunError.unknownStep(checkpoint.next)))) }
    return .resume(Resumable(record: record, job: snapshot.job, pipeline: pipeline, checkpoint: checkpoint, control: AttemptControl(job: snapshot.job.ref)))
  }

  static func settle(_ id: AttemptID, _ settlement: AttemptSettlement, by writer: ReplicaID, in transaction: inout WriteTransaction) throws {
    do {
      try AttemptRecords.update(id, AttemptUpdate(settlement: settlement), by: writer, in: &transaction)
    } catch .attemptSettled, .notWriter {
      logger.notice("An attempt this device ran was already settled or is not its own attempt=\(id.uuid.lowercasedString, privacy: .public)")
    }
    try JobsLocal.forget(id, in: transaction.database)
  }

  /// Nothing is written once the attempt crashed, as nothing is written after a process ends.
  func write<T: Sendable>(_ control: AttemptControl, _ body: @Sendable (inout WriteTransaction) throws -> T) async throws(JobRunError) -> T {
    let result = try await storeWrite { transaction in
      guard !control.isCrashed else { throw JobRunError.interrupted }
      return try body(&transaction)
    }
    if faults.crashes(.committed(write: control.countWrite())) { control.crash() }
    return result
  }

  private func storeWrite<T: Sendable>(_ body: @Sendable (inout WriteTransaction) throws -> T) async throws(JobRunError) -> T {
    do {
      return try await store.write(body)
    } catch {
      throw JobRunError(error)
    }
  }

  private func launch(_ run: AttemptRun, from checkpoint: LocalCheckpoint) -> AttemptHandle {
    AttemptHandle(attempt: run.record.id, job: run.job.ref, task: Task { await run.drive(from: checkpoint) })
  }

  func reserve(_ id: AttemptID, _ control: AttemptControl) throws(JobRunError) {
    let existing = running.withLock { running -> AttemptID? in
      if let existing = running.first(where: { $0.value.job == control.job })?.key { return existing }
      running[id] = control
      return nil
    }
    if let existing { throw .alreadyRunningHere(existing) }
  }

  private func isRunning(_ id: AttemptID) -> Bool {
    running.withLock { $0[id] != nil }
  }

  func release(_ id: AttemptID) {
    _ = running.withLock { $0.removeValue(forKey: id) }
  }
}
