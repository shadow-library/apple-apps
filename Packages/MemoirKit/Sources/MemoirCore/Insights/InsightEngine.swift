import Foundation
import ShadowAI
import ShadowCore
import ShadowJobs
import ShadowStore

/// What `runDue` found for tonight's standing question.
public enum InsightDue: Sendable {
  case notScheduled
  /// The router's provider still needs the owner's consent to the insight call; no attempt was started.
  case waitingForConsent(AIConsentRequest)
  /// A spend cap is reached; no attempt was started.
  case waitingForSpend(SpendDecision)
  case started(AttemptHandle)
  /// An attempt holds a live lease, here or on another device.
  case running(EntityRef)
  case succeeded(EntityRef)
  case cancelled(EntityRef)
  /// Failed for good: a refusal, a guardrail block, or the attempt limit reached.
  case failed(EntityRef, code: String)
}

/// Runs this vault's insights on this device, one engine per vault. A scheduled insight is a job for its night: the Mac worker runs it at the scheduled
/// minute when awake and any device runs it at its next open otherwise, since `runDue` asks for the same job on every device and the job's lease lets one
/// attempt run. Each attempt reads consent and the owner's data afresh, and nothing assembled is checkpointed.
public final class InsightEngine: Sendable {
  public typealias RouterSource = @Sendable () async -> TaskRouter

  /// `ai.max-attempts` (bootstrap.ts:141).
  public static let maximumAttempts = 3

  let stores: MemoirStores
  let runner: AttemptRunner
  let clock: LeaseClock
  let services: InsightServices

  public convenience init(
    stores: MemoirStores, replay: any InsightReplaySource, router: @escaping RouterSource, clock: LeaseClock, pace: Pace = .steady,
    budget: Int = InsightAssembler.defaultBudget
  ) {
    self.init(stores: stores, replay: replay, router: router, clock: clock, runner: AttemptRunner(store: stores.main, clock: clock), pace: pace, budget: budget)
  }

  init(
    stores: MemoirStores, replay: any InsightReplaySource, router: @escaping RouterSource, clock: LeaseClock, runner: AttemptRunner, pace: Pace, budget: Int
  ) {
    self.stores = stores
    self.runner = runner
    self.clock = clock
    services = InsightServices(
      stores: stores, assembler: InsightAssembler(stores: stores, replay: replay, budget: budget), router: router, pace: pace, now: { clock.now() })
  }

  var pipeline: AttemptPipeline {
    AttemptPipeline(first: InsightStep.name, steps: [InsightStep.name: InsightStep(services: services)])
  }

  /// An ad-hoc question under the id the app minted for it: asking the same id again answers the job already asked.
  public func ask(_ question: String, id: UUID) async throws(InsightError) -> InsightDue {
    let request = try InsightJob.request(.adhoc, target: .question(id), question: question, replica: stores.main.replica)
    return try await drive(request)
  }

  /// The night due at `local` (the account zone's date and minute, from `IssueClock`): the latest night whose scheduled minute has passed.
  public func runDue(at local: ZonedFields) async throws(InsightError) -> InsightDue {
    let schedule: InsightScheduleRecord?
    do {
      schedule = try await stores.main.read { transaction in try InsightScheduleRecord.read(key: .insightSchedule, in: transaction).entry?.record }
    } catch {
      throw .converting(error)
    }
    guard let schedule, let night = InsightSchedules.dueNight(of: schedule, at: local) else { return .notScheduled }
    return try await drive(try InsightJob.request(.scheduled, target: .night(night), question: schedule.question, replica: stores.main.replica))
  }

  /// Asks a request again: its own run while another attempt may still start, the next run once it failed for good or was cancelled. A request that
  /// succeeded or runs is left as it is.
  public func retry(job ref: EntityRef) async throws(InsightError) -> InsightDue {
    let existing = try await requireSnapshot(ref)
    let job = try InsightJob(existing.job)
    switch verdict(existing) {
    case nil:
      return try await drive(existing.job.request)
    case .cancelled?, .failed?:
      let run = existing.job.request.key.run + 1
      return try await drive(try InsightJob.request(job.kind, target: job.target, question: job.question, replica: stores.main.replica, run: run))
    case let settled?:
      return settled
    }
  }

  /// Cancels the request and stops this device's attempt of it; an answer already stored stays.
  public func cancel(job ref: EntityRef) async throws(InsightError) -> JobCancelOutcome {
    guard InsightJobAddress.kind(of: try await requireSnapshot(ref).job.request.key) != nil else { throw .notAnInsightJob(ref) }
    do {
      return try await runner.cancel(job: ref)
    } catch {
      throw .run(error)
    }
  }

  /// Continues this device's interrupted insight attempts from their checkpoints.
  public func resumeInterrupted() async throws(InsightError) -> [AttemptHandle] {
    let pipeline = pipeline
    do {
      return try await runner.resumeInterrupted { job in InsightJobAddress.kind(of: job.request.key) == nil ? nil : pipeline }
    } catch {
      throw .run(error)
    }
  }

  /// What keeps a call from being sent now, checked before an attempt is spent on it, as the reference holds a task rather than failing it.
  private func hold() async throws(InsightError) -> InsightDue? {
    let router = await services.router()
    do {
      if let missing = try await router.missingConsent(InsightConsent.call) { return .waitingForConsent(missing) }
      let spend = try await router.spendDecision()
      return spend == .allowed ? nil : .waitingForSpend(spend)
    } catch {
      throw .routing(error)
    }
  }

  /// Starts an attempt unless the job succeeded, runs, was cancelled or failed for good, or a call could not be sent now; the job is written only when an
  /// attempt can start.
  private func drive(_ request: JobRequest) async throws(InsightError) -> InsightDue {
    let ref = request.key.ref
    if let existing = try await snapshot(ref), let settled = verdict(existing) { return settled }
    if let held = try await hold() { return held }
    let requested: JobSnapshot
    do {
      requested = try await stores.main.write { transaction in
        let job = try JobRecords.request(request, in: &transaction).job
        guard let snapshot = try JobSnapshot.load(job.ref, in: transaction) else { throw JobRecordError.jobNotFound(job.ref) }
        return snapshot
      }
    } catch {
      throw .converting(error)
    }
    if let settled = verdict(requested) { return settled }
    do {
      return .started(try await runner.start(job: ref, pipeline: pipeline, input: .null))
    } catch .anotherAttemptLive, .alreadyRunningHere {
      return .running(ref)
    } catch .jobSucceeded {
      return .succeeded(ref)
    } catch .jobCancelled {
      return .cancelled(ref)
    } catch {
      throw .run(error)
    }
  }

  private func requireSnapshot(_ ref: EntityRef) async throws(InsightError) -> JobSnapshot {
    guard let existing = try await snapshot(ref) else { throw .job(.jobNotFound(ref)) }
    return existing
  }

  private func snapshot(_ ref: EntityRef) async throws(InsightError) -> JobSnapshot? {
    do {
      return try await stores.main.read { transaction in try JobSnapshot.load(ref, in: transaction) }
    } catch {
      throw .converting(error)
    }
  }

  /// Nil when another attempt may start. An attempt that failed only because a call could not be sent then does not count towards the limit.
  private func verdict(_ snapshot: JobSnapshot) -> InsightDue? {
    let ref = snapshot.job.ref
    switch JobStatus(snapshot, at: clock.now()) {
    case .succeeded: return .succeeded(ref)
    case .cancelled: return .cancelled(ref)
    case .running: return .running(ref)
    case .queued: return nil
    case .failed(_, let failure):
      let code = failure?.code ?? "jobs.step_failed"
      let counted = snapshot.attempts.count { $0.outcome == .failed && !InsightError.isHold(code: $0.error?.code ?? "jobs.step_failed") }
      return InsightError.isRetryable(code: code) && counted < Self.maximumAttempts ? nil : .failed(ref, code: code)
    }
  }
}

/// The owner's standing question.
public enum InsightSchedules {
  public static let minutesPerDay = 1440

  /// Sets or replaces the standing question; a night already asked keeps the question it was asked with.
  public static func set(_ schedule: InsightScheduleRecord, in transaction: inout WriteTransaction) throws(InsightError) {
    _ = try InsightQuestion.validated(schedule.question)
    for minute in [schedule.minuteOfDay, schedule.setAtMinute] where !(0..<minutesPerDay).contains(minute) { throw .scheduleMinuteOutOfRange(minute) }
    let exists: Bool
    do {
      exists = try InsightScheduleRecord.read(key: .insightSchedule, in: transaction) != .absent
    } catch {
      throw .store(error)
    }
    do {
      if exists {
        try InsightScheduleRecord.edit(MemoirKey.insightSchedule.ref, in: &transaction) { current in current = schedule }
      } else {
        try schedule.create(in: &transaction)
      }
    } catch {
      throw .record(error)
    }
  }

  /// Only the latest night is ever due, so a device asleep for a week runs one insight, not seven; a night whose minute had passed when the schedule was
  /// set is never due, so setting it runs nothing until its next minute.
  public static func dueNight(of schedule: InsightScheduleRecord, at local: ZonedFields) -> LocalDate? {
    guard schedule.active, let night = local.minuteOfDay >= schedule.minuteOfDay ? local.date : local.date.adding(days: -1) else { return nil }
    let firstNight = schedule.setAtMinute <= schedule.minuteOfDay ? schedule.setOn : schedule.setOn.adding(days: 1)
    guard let firstNight, night >= firstNight else { return nil }
    return night
  }
}
