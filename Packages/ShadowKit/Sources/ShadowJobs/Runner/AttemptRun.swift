import Foundation
import OSLog
import ShadowCore
import ShadowStore

struct AttemptRun: Sendable {
  let runner: AttemptRunner
  let record: AttemptRecord
  let job: JobRecord
  let pipeline: AttemptPipeline
  let control: AttemptControl

  private var id: AttemptID { record.id }
  private var writer: ReplicaID { record.start.replica }

  func drive(from checkpoint: LocalCheckpoint) async -> AttemptResult {
    let heartbeat = Task { await beat() }
    let watcher = Task { await watch() }
    let result = await steps(from: checkpoint)
    heartbeat.cancel()
    watcher.cancel()
    await heartbeat.value
    await watcher.value
    runner.release(id)
    return result
  }

  private func steps(from start: LocalCheckpoint) async -> AttemptResult {
    var checkpoint = start
    while true {
      if control.isCrashed { return .interrupted }
      if let stop = control.stop { return await settle(stop.settlement) }
      if let stop = await boundaryStop() {
        await halt(stop)
        continue
      }
      guard let step = pipeline.steps[checkpoint.next] else { return await settle(.failed(AttemptFailure(JobRunError.unknownStep(checkpoint.next)))) }
      let ran = await run(step, from: checkpoint)
      if control.isCrashed { return .interrupted }
      let output: AttemptStepOutput
      switch ran {
      case .success(let succeeded):
        output = succeeded
      case .failure(let error):
        return await settle(control.stop?.settlement ?? .failed(AttemptFailure(error)))
      }
      if runner.faults.crashes(.beforeCommit(step: checkpoint.index)) { return crash() }
      let next: LocalCheckpoint?
      do {
        next = try await commit(output, after: checkpoint)
      } catch {
        if control.isCrashed { return .interrupted }
        return await settle(.failed(AttemptFailure(error.underlying)))
      }
      if control.isCrashed { return .interrupted }
      if runner.faults.crashes(.afterCommit(step: checkpoint.index)) { return crash() }
      guard let next else { return .settled(.succeeded) }
      checkpoint = next
    }
  }

  private func run(_ step: any PipelineStep, from checkpoint: LocalCheckpoint) async -> Result<AttemptStepOutput, any Error> {
    let (faults, control, index) = (runner.faults, control, checkpoint.index)
    let context = AttemptStepContext(
      attempt: id, job: job, start: record.start, step: AttemptStep(name: checkpoint.next, index: index), control: control,
      opened: { if faults.crashes(.call(step: index)) { control.crash(cancellingStep: false) } })
    let task = Task { try await step.run(checkpoint.state, in: context) }
    control.attach { task.cancel() }
    defer { control.detach() }
    do {
      return .success(try await task.value)
    } catch {
      return .failure(error)
    }
  }

  /// One transaction, so a step's output is written once or not at all; the last step's commits with the attempt's success.
  private func commit(_ output: AttemptStepOutput, after checkpoint: LocalCheckpoint) async throws(JobRunError) -> LocalCheckpoint? {
    if let next = output.next, pipeline.steps[next] == nil { throw JobRunError.unknownStep(next) }
    let (id, writer, clock) = (id, writer, runner.clock)
    return try await runner.write(control) { transaction in
      try output.writes(&transaction)
      guard let name = output.next else {
        try AttemptRecords.update(id, AttemptUpdate(settlement: .succeeded), by: writer, in: &transaction)
        try JobsLocal.forget(id, in: transaction.database)
        return nil
      }
      let now = clock.now()
      let next = LocalCheckpoint(attempt: id, index: checkpoint.index + 1, next: name, state: output.state)
      try AttemptRecords.update(id, AttemptUpdate(lease: .granted(at: now), step: AttemptStep(name: name, index: next.index)), by: writer, in: &transaction)
      try JobsLocal.save(next, at: now.date, in: transaction.database)
      return next
    }
  }

  private func settle(_ settlement: AttemptSettlement) async -> AttemptResult {
    if runner.faults.crashes(.settling) { return crash() }
    let (id, writer) = (id, writer)
    do {
      try await runner.write(control) { transaction in try AttemptRunner.settle(id, settlement, by: writer, in: &transaction) }
      return .settled(settlement)
    } catch {
      AttemptRunner.logger.error("Could not record how an attempt ended attempt=\(id.uuid.lowercasedString, privacy: .public) code=\(error.code, privacy: .public)")
      return .interrupted
    }
  }

  private func crash() -> AttemptResult {
    control.crash()
    return .interrupted
  }

  private func boundaryStop() async -> LocalStop? {
    let ref = job.ref
    guard let snapshot = try? await runner.store.read({ transaction in try JobSnapshot.load(ref, in: transaction) }) else { return nil }
    return stop(for: snapshot)
  }

  private func stop(for snapshot: JobSnapshot) -> LocalStop? {
    guard let own = snapshot.attempts.first(where: { $0.id == id }) else { return nil }
    switch AttemptVerdict(for: own, in: snapshot, at: runner.clock.now()) {
    case .proceed: return nil
    case .cancel: return .cancelled
    case .standDown: return .stoodDown
    }
  }

  private func halt(_ stop: LocalStop) async {
    guard control.stop(stop) else { return }
    let (id, now) = (id, runner.clock.now())
    do {
      try await runner.write(control) { transaction in _ = try JobsLocal.markStopped(id, as: stop, at: now.date, in: transaction.database) }
    } catch {
      AttemptRunner.logger.notice("Could not mark an attempt stopped attempt=\(id.uuid.lowercasedString, privacy: .public) code=\(error.code, privacy: .public)")
    }
  }

  private func watch() async {
    let ref = job.ref
    do {
      for try await snapshot in runner.store.observeReads({ transaction in try JobSnapshot.load(ref, in: transaction) }) {
        guard let snapshot, let stop = stop(for: snapshot) else { continue }
        await halt(stop)
        return
      }
    } catch {
      AttemptRunner.logger.notice("Stopped watching an attempt's job attempt=\(id.uuid.lowercasedString, privacy: .public)")
    }
  }

  private func beat() async {
    let (id, writer, clock) = (id, writer, runner.clock)
    while true {
      do {
        try await runner.timing.sleep(runner.timing.heartbeat)
      } catch {
        return
      }
      if Task.isCancelled || control.isCrashed { return }
      if runner.faults.crashes(.renewing) {
        control.crash()
        return
      }
      do {
        _ = try await runner.write(control) { transaction in try AttemptRecords.update(id, AttemptUpdate(lease: .granted(at: clock.now())), by: writer, in: &transaction) }
      } catch .record(.attemptSettled), .record(.notWriter), .interrupted {
        return
      } catch {
        AttemptRunner.logger.error("Could not renew an attempt's lease attempt=\(id.uuid.lowercasedString, privacy: .public) code=\(error.code, privacy: .public)")
      }
      if runner.faults.crashes(.renewed) {
        control.crash()
        return
      }
    }
  }
}
